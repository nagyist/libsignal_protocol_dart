import 'dart:collection';
import 'dart:core';
import 'dart:math';
import 'dart:typed_data';

import 'package:libsignalprotocoldart/src/DecryptionCallback.dart';
import 'package:libsignalprotocoldart/src/DuplicateMessageException.dart';
import 'package:libsignalprotocoldart/src/InvalidKeyException.dart';
import 'package:libsignalprotocoldart/src/InvalidMessageException.dart';
import 'package:libsignalprotocoldart/src/NoSessionException.dart';
import 'package:libsignalprotocoldart/src/SessionBuilder.dart';
import 'package:libsignalprotocoldart/src/SignalProtocolAddress.dart';
import 'package:libsignalprotocoldart/src/UntrustedIdentityException.dart';
import 'package:libsignalprotocoldart/src/ecc/Curve.dart';
import 'package:libsignalprotocoldart/src/ecc/ECPublicKey.dart';
import 'package:libsignalprotocoldart/src/protocol/CiphertextMessage.dart';
import 'package:libsignalprotocoldart/src/protocol/PreKeySignalMessage.dart';
import 'package:libsignalprotocoldart/src/protocol/SignalMessage.dart';
import 'package:libsignalprotocoldart/src/ratchet/ChainKey.dart';
import 'package:libsignalprotocoldart/src/ratchet/MessageKeys.dart';
import 'package:libsignalprotocoldart/src/state/IdentityKeyStore.dart';
import 'package:libsignalprotocoldart/src/state/PreKeyStore.dart';
import 'package:libsignalprotocoldart/src/state/SessionRecord.dart';
import 'package:libsignalprotocoldart/src/state/SessionState.dart';
import 'package:libsignalprotocoldart/src/state/SessionStore.dart';
import 'package:libsignalprotocoldart/src/state/SignalProtocolStore.dart';
import 'package:libsignalprotocoldart/src/state/SignedPreKeyStore.dart';

class SessionCipher {
  static final Object SESSION_LOCK = Object();

  SessionStore _sessionStore;
  IdentityKeyStore _identityKeyStore;
  SessionBuilder _sessionBuilder;
  PreKeyStore _preKeyStore;
  SignalProtocolAddress _remoteAddress;

  SessionCipher(
      this._sessionStore,
      this._preKeyStore,
      SignedPreKeyStore signedPreKeyStore,
      this._identityKeyStore,
      this._remoteAddress) {
    _sessionBuilder = SessionBuilder(_sessionStore, _preKeyStore,
        signedPreKeyStore, _identityKeyStore, _remoteAddress);
  }

  SessionCipher.fromStore(
      SignalProtocolStore store, SignalProtocolAddress remoteAddress) {
    SessionCipher(store, store, store, store, remoteAddress);
  }

  CiphertextMessage encrypt(Uint8List paddedMessage) {
    synchronized(SESSION_LOCK) {
      SessionRecord sessionRecord = _sessionStore.loadSession(_remoteAddress);
      SessionState sessionState = sessionRecord.getSessionState();
      ChainKey chainKey = sessionState.getSenderChainKey();
      MessageKeys messageKeys = chainKey.getMessageKeys();
      ECPublicKey senderEphemeral = sessionState.getSenderRatchetKey();
      int previousCounter = sessionState.getPreviousCounter();
      int sessionVersion = sessionState.getSessionVersion();

      Uint8List ciphertextBody = getCiphertext(messageKeys, paddedMessage);
      CiphertextMessage ciphertextMessage = SignalMessage(
          sessionVersion,
          messageKeys.getMacKey(),
          senderEphemeral,
          chainKey.getIndex(),
          previousCounter,
          ciphertextBody,
          sessionState.getLocalIdentityKey(),
          sessionState.getRemoteIdentityKey());

      if (sessionState.hasUnacknowledgedPreKeyMessage()) {
        UnacknowledgedPreKeyMessageItems items =
            sessionState.getUnacknowledgedPreKeyMessageItems();
        int localRegistrationId = sessionState.getLocalRegistrationId();

        ciphertextMessage = PreKeySignalMessage.from(
            sessionVersion,
            localRegistrationId,
            items.getPreKeyId(),
            items.getSignedPreKeyId(),
            items.getBaseKey(),
            sessionState.getLocalIdentityKey(),
            ciphertextMessage as SignalMessage);
      }

      sessionState.setSenderChainKey(chainKey.getNextChainKey());

      if (!_identityKeyStore.isTrustedIdentity(_remoteAddress,
          sessionState.getRemoteIdentityKey(), Direction.SENDING)) {
        throw UntrustedIdentityException(
            _remoteAddress.getName(), sessionState.getRemoteIdentityKey());
      }

      _identityKeyStore.saveIdentity(
          _remoteAddress, sessionState.getRemoteIdentityKey());
      _sessionStore.storeSession(_remoteAddress, sessionRecord);
      return ciphertextMessage;
    }
  }

  Uint8List decrypt(PreKeySignalMessage ciphertext) {
    return decryptWithCallback(ciphertext, NullDecryptionCallback());
  }

  Uint8List decryptWithCallback(
      PreKeySignalMessage ciphertext, DecryptionCallback callback) {
    synchronized(SESSION_LOCK) {
      var sessionRecord = _sessionStore.loadSession(_remoteAddress);
      var unsignedPreKeyId = _sessionBuilder.process(sessionRecord, ciphertext);
      var plaintext = _decrypt(sessionRecord, ciphertext.getWhisperMessage());

      callback.handlePlaintext(plaintext);

      _sessionStore.storeSession(_remoteAddress, sessionRecord);

      if (unsignedPreKeyId.isPresent) {
        _preKeyStore.removePreKey(unsignedPreKeyId.value);
      }

      return plaintext;
    }
  }

  Uint8List decryptFromSignal(SignalMessage ciphertext) {
    return decryptFromSignalWithCallback(ciphertext, NullDecryptionCallback());
  }

  Uint8List decryptFromSignalWithCallback(
      SignalMessage ciphertext, DecryptionCallback callback) {
    synchronized(SESSION_LOCK) {
      if (!_sessionStore.containsSession(_remoteAddress)) {
        throw NoSessionException('No session for: $_remoteAddress');
      }

      SessionRecord sessionRecord = _sessionStore.loadSession(_remoteAddress);
      Uint8List plaintext = _decrypt(sessionRecord, ciphertext);

      if (!_identityKeyStore.isTrustedIdentity(
          _remoteAddress,
          sessionRecord.getSessionState().getRemoteIdentityKey(),
          Direction.RECEIVING)) {
        throw UntrustedIdentityException(_remoteAddress.getName(),
            sessionRecord.getSessionState().getRemoteIdentityKey());
      }

      _identityKeyStore.saveIdentity(_remoteAddress,
          sessionRecord.getSessionState().getRemoteIdentityKey());

      callback.handlePlaintext(plaintext);

      _sessionStore.storeSession(_remoteAddress, sessionRecord);

      return plaintext;
    }
  }

  Uint8List _decrypt(SessionRecord sessionRecord, SignalMessage ciphertext) {
    synchronized(SESSION_LOCK) {
      Iterator<SessionState> previousStates =
          sessionRecord.getPreviousSessionStates().iterator;
      var exceptions = [];

      try {
        SessionState sessionState =
            SessionState.fromSessionState(sessionRecord.getSessionState());
        var plaintext = _decryptFromState(sessionState, ciphertext);

        sessionRecord.setState(sessionState);
        return plaintext;
      } on InvalidMessageException catch (e) {
        exceptions.add(e);
      }
      var _previousStates = HasNextIterator(previousStates);
      while (_previousStates.hasNext) {
        try {
          var promotedState =
              SessionState.fromSessionState(_previousStates.next());
          var plaintext = _decryptFromState(promotedState, ciphertext);

          // _previousStates.remove();
          sessionRecord.promoteState(promotedState);

          return plaintext;
        } on InvalidMessageException catch (e) {
          exceptions.add(e);
        }
      }

      throw InvalidMessageException("No valid sessions. $exceptions[0]");
    }
  }

  Uint8List _decryptFromState(
      SessionState sessionState, SignalMessage ciphertextMessage) {
    if (!sessionState.hasSenderChain()) {
      throw InvalidMessageException("Uninitialized session!");
    }

    if (ciphertextMessage.getMessageVersion() !=
        sessionState.getSessionVersion()) {
      throw InvalidMessageException(
          "Message version $ciphertextMessage.getMessageVersion(), but session version $sessionState.getSessionVersion()");
    }

    ECPublicKey theirEphemeral = ciphertextMessage.getSenderRatchetKey();
    int counter = ciphertextMessage.getCounter();
    ChainKey chainKey = _getOrCreateChainKey(sessionState, theirEphemeral);
    MessageKeys messageKeys = _getOrCreateMessageKeys(
        sessionState, theirEphemeral, chainKey, counter);

    ciphertextMessage.verifyMac(sessionState.getRemoteIdentityKey(),
        sessionState.getLocalIdentityKey(), messageKeys.getMacKey());

    Uint8List plaintext =
        _getPlaintext(messageKeys, ciphertextMessage.getBody());

    sessionState.clearUnacknowledgedPreKeyMessage();

    return plaintext;
  }

  int getRemoteRegistrationId() {
    synchronized(SESSION_LOCK) {
      SessionRecord record = _sessionStore.loadSession(_remoteAddress);
      return record.getSessionState().getRemoteRegistrationId();
    }
  }

  int getSessionVersion() {
    synchronized(SESSION_LOCK) {
      if (!_sessionStore.containsSession(_remoteAddress)) {
        // throw IllegalStateException("No session for ($_remoteAddress)!");
      }

      var record = _sessionStore.loadSession(_remoteAddress);
      return record.getSessionState().getSessionVersion();
    }
  }

  ChainKey _getOrCreateChainKey(
      SessionState sessionState, ECPublicKey theirEphemeral) {
    try {
      if (sessionState.hasReceiverChain(theirEphemeral)) {
        return sessionState.getReceiverChainKey(theirEphemeral);
      } else {
        var rootKey = sessionState.getRootKey();
        var ourEphemeral = sessionState.getSenderRatchetKeyPair();
        var receiverChain = rootKey.createChain(theirEphemeral, ourEphemeral);
        var ourNewEphemeral = Curve.generateKeyPair();
        var senderChain =
            receiverChain.item1.createChain(theirEphemeral, ourNewEphemeral);

        sessionState.setRootKey(senderChain.item1);
        sessionState.addReceiverChain(theirEphemeral, receiverChain.item2);
        sessionState.setPreviousCounter(
            max(sessionState.getSenderChainKey().getIndex() - 1, 0));
        sessionState.setSenderChain(ourNewEphemeral, senderChain.item2);

        return receiverChain.item2;
      }
    } on InvalidKeyException catch (e) {
      throw e;
    }
  }

  MessageKeys _getOrCreateMessageKeys(SessionState sessionState,
      ECPublicKey theirEphemeral, ChainKey chainKey, int counter) {
    if (chainKey.getIndex() > counter) {
      if (sessionState.hasMessageKeys(theirEphemeral, counter)) {
        return sessionState.removeMessageKeys(theirEphemeral, counter);
      } else {
        throw DuplicateMessageException(
            'Received message with old counter: $chainKey.getIndex(), $counter');
      }
    }

    if (counter - chainKey.getIndex() > 2000) {
      throw InvalidMessageException('Over 2000 messages into the future!');
    }

    while (chainKey.getIndex() < counter) {
      var messageKeys = chainKey.getMessageKeys();
      sessionState.setMessageKeys(theirEphemeral, messageKeys);
      chainKey = chainKey.getNextChainKey();
    }

    sessionState.setReceiverChainKey(
        theirEphemeral, chainKey.getNextChainKey());
    return chainKey.getMessageKeys();
  }

  Uint8List getCiphertext(MessageKeys messageKeys, Uint8List plaintext) {
    // try {
    //   Cipher cipher = getCipher(Cipher.ENCRYPT_MODE, messageKeys.getCipherKey(), messageKeys.getIv());
    //   return cipher.doFinal(plaintext);
    // } catch (IllegalBlockSizeException | BadPaddingException e) {
    //   throw new AssertionError(e);
    // }
  }

  Uint8List _getPlaintext(MessageKeys messageKeys, Uint8List cipherText) {
    // try {
    //   Cipher cipher = getCipher(Cipher.DECRYPT_MODE, messageKeys.getCipherKey(), messageKeys.getIv());
    //   return cipher.doFinal(cipherText);
    // } catch (IllegalBlockSizeException | BadPaddingException e) {
    //   throw new InvalidMessageException(e);
    // }
  }

  /*
   Cipher _getCipher(int mode, SecretKeySpec key, IvParameterSpec iv) {
    try {
      Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
      cipher.init(mode, key, iv);
      return cipher;
    } catch (NoSuchAlgorithmException | NoSuchPaddingException | java.security.InvalidKeyException |
             InvalidAlgorithmParameterException e)
    {
      throw new AssertionError(e);
    }
    */

}

class NullDecryptionCallback implements DecryptionCallback {
  @override
  void handlePlaintext(Uint8List plaintext) {}
}