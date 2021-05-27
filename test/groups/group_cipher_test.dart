import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/src/duplicate_message_exception.dart';
import 'package:libsignal_protocol_dart/src/invalid_message_exception.dart';
import 'package:libsignal_protocol_dart/src/no_session_exception.dart';
import 'package:libsignal_protocol_dart/src/signal_protocol_address.dart';
import 'package:libsignal_protocol_dart/src/eq.dart';
import 'package:libsignal_protocol_dart/src/groups/group_cipher.dart';
import 'package:libsignal_protocol_dart/src/groups/group_session_builder.dart';
import 'package:libsignal_protocol_dart/src/groups/sender_key_name.dart';
import 'package:libsignal_protocol_dart/src/groups/state/in_memory_sender_key_store.dart';
import 'package:libsignal_protocol_dart/src/protocol/sender_key_distribution_message_wrapper.dart';
import 'package:libsignal_protocol_dart/src/util/key_helper.dart';
import 'package:test/test.dart';

void main() {
  final SENDER_ADDRESS = SignalProtocolAddress('+14150001111', 1);
  final GROUP_SENDER =
      SenderKeyName('nihilist history reading group', SENDER_ADDRESS);

  const _integerMax = 0x7fffffff;

  int _randomInt() {
    final secureRandom = Random.secure();
    return secureRandom.nextInt(_integerMax);
  }

  test('testNoSession', () async {
    final aliceStore = InMemorySenderKeyStore();
    final bobStore = InMemorySenderKeyStore();

    final aliceSessionBuilder = GroupSessionBuilder(aliceStore);
    final bobSessionBuilder = GroupSessionBuilder(bobStore);

    final aliceGroupCipher = GroupCipher(aliceStore, GROUP_SENDER);
    final bobGroupCipher = GroupCipher(bobStore, GROUP_SENDER);

    final sentAliceDistributionMessage =
        await aliceSessionBuilder.create(GROUP_SENDER);
    final receivedAliceDistributionMessage =
        SenderKeyDistributionMessageWrapper.fromSerialized(
            sentAliceDistributionMessage.serialize());

//    bobSessionBuilder.process(GROUP_SENDER, receivedAliceDistributionMessage);

    final ciphertextFromAlice = await aliceGroupCipher
        .encrypt(Uint8List.fromList(utf8.encode('smert ze smert')));
    try {
      final plaintextFromAlice =
          await bobGroupCipher.decrypt(ciphertextFromAlice);
      throw AssertionError('Should be no session!');
    } on NoSessionException {
      // good
    }
  });

  test('testBasicEncryptDecrypt', () async {
    final aliceStore = InMemorySenderKeyStore();
    final bobStore = InMemorySenderKeyStore();

    final aliceSessionBuilder = GroupSessionBuilder(aliceStore);
    final bobSessionBuilder = GroupSessionBuilder(bobStore);

    final aliceGroupCipher = GroupCipher(aliceStore, GROUP_SENDER);
    final bobGroupCipher = GroupCipher(bobStore, GROUP_SENDER);

    final sentAliceDistributionMessage =
        await aliceSessionBuilder.create(GROUP_SENDER);
    final receivedAliceDistributionMessage =
        SenderKeyDistributionMessageWrapper.fromSerialized(
            sentAliceDistributionMessage.serialize());
    await bobSessionBuilder.process(
        GROUP_SENDER, receivedAliceDistributionMessage);

    final ciphertextFromAlice = await aliceGroupCipher
        .encrypt(Uint8List.fromList(utf8.encode('smert ze smert')));
    final plaintextFromAlice =
        await bobGroupCipher.decrypt(ciphertextFromAlice);

    assert(utf8.decode(plaintextFromAlice) == 'smert ze smert');
  });

  test('testLargeMessages', () async {
    final aliceStore = InMemorySenderKeyStore();
    final bobStore = InMemorySenderKeyStore();

    final aliceSessionBuilder = GroupSessionBuilder(aliceStore);
    final bobSessionBuilder = GroupSessionBuilder(bobStore);

    final aliceGroupCipher = GroupCipher(aliceStore, GROUP_SENDER);
    final bobGroupCipher = GroupCipher(bobStore, GROUP_SENDER);

    final sentAliceDistributionMessage =
        await aliceSessionBuilder.create(GROUP_SENDER);
    final receivedAliceDistributionMessage =
        SenderKeyDistributionMessageWrapper.fromSerialized(
            sentAliceDistributionMessage.serialize());
    await bobSessionBuilder.process(
        GROUP_SENDER, receivedAliceDistributionMessage);

    final plaintext = generateRandomBytes(1024 * 1024);

    final ciphertextFromAlice = await aliceGroupCipher.encrypt(plaintext);
    final plaintextFromAlice =
        await bobGroupCipher.decrypt(ciphertextFromAlice);

    assert(eq(plaintextFromAlice, plaintext));
  });

  test('testBasicRatchet', () async {
    final aliceStore = InMemorySenderKeyStore();
    final bobStore = InMemorySenderKeyStore();

    final aliceSessionBuilder = GroupSessionBuilder(aliceStore);
    final bobSessionBuilder = GroupSessionBuilder(bobStore);

    final aliceName = GROUP_SENDER;

    final aliceGroupCipher = GroupCipher(aliceStore, aliceName);
    final bobGroupCipher = GroupCipher(bobStore, aliceName);

    final sentAliceDistributionMessage =
        await aliceSessionBuilder.create(aliceName);
    final receivedAliceDistributionMessage =
        SenderKeyDistributionMessageWrapper.fromSerialized(
            sentAliceDistributionMessage.serialize());

    await bobSessionBuilder.process(
        aliceName, receivedAliceDistributionMessage);

    final ciphertextFromAlice = await aliceGroupCipher
        .encrypt(Uint8List.fromList(utf8.encode('smert ze smert')));
    final ciphertextFromAlice2 = await aliceGroupCipher
        .encrypt(Uint8List.fromList(utf8.encode('smert ze smert2')));
    final ciphertextFromAlice3 = await aliceGroupCipher
        .encrypt(Uint8List.fromList(utf8.encode('smert ze smert3')));

    final plaintextFromAlice =
        await bobGroupCipher.decrypt(ciphertextFromAlice);

    try {
      await bobGroupCipher.decrypt(ciphertextFromAlice);
      throw AssertionError('Should have ratcheted forward!');
    } on DuplicateMessageException {
      // good
    }

    final plaintextFromAlice2 =
        await bobGroupCipher.decrypt(ciphertextFromAlice2);
    final plaintextFromAlice3 =
        await bobGroupCipher.decrypt(ciphertextFromAlice3);

    assert(utf8.decode(plaintextFromAlice) == 'smert ze smert');
    assert(utf8.decode(plaintextFromAlice2) == 'smert ze smert2');
    assert(utf8.decode(plaintextFromAlice3) == 'smert ze smert3');
  });

  test('testLateJoin', () async {
    final aliceStore = InMemorySenderKeyStore();
    final bobStore = InMemorySenderKeyStore();

    final aliceSessionBuilder = GroupSessionBuilder(aliceStore);

    final aliceName = GROUP_SENDER;

    final aliceGroupCipher = GroupCipher(aliceStore, aliceName);

    final aliceDistributionMessage =
        await aliceSessionBuilder.create(aliceName);
    // Send off to some people.

    for (var i = 0; i < 100; i++) {
      await aliceGroupCipher.encrypt(Uint8List.fromList(
          utf8.encode('up the punks up the punks up the punks')));
    }

    // Now Bob Joins.
    final bobSessionBuilder = GroupSessionBuilder(bobStore);
    final bobGroupCipher = GroupCipher(bobStore, aliceName);

    final distributionMessageToBob =
        await aliceSessionBuilder.create(aliceName);
    await bobSessionBuilder.process(
        aliceName,
        SenderKeyDistributionMessageWrapper.fromSerialized(
            distributionMessageToBob.serialize()));

    final ciphertext = await aliceGroupCipher
        .encrypt(Uint8List.fromList(utf8.encode('welcome to the group')));
    final plaintext = await bobGroupCipher.decrypt(ciphertext);

    assert(utf8.decode(plaintext) == 'welcome to the group');
  });

  test('testOutOfOrder', () async {
    final aliceStore = InMemorySenderKeyStore();
    final bobStore = InMemorySenderKeyStore();

    final aliceSessionBuilder = GroupSessionBuilder(aliceStore);
    final bobSessionBuilder = GroupSessionBuilder(bobStore);

    final aliceName = GROUP_SENDER;

    final aliceGroupCipher = GroupCipher(aliceStore, aliceName);
    final bobGroupCipher = GroupCipher(bobStore, aliceName);

    final sentAliceDistributionMessage =
        await aliceSessionBuilder.create(aliceName);
    final receivedAliceDistributionMessage =
        SenderKeyDistributionMessageWrapper.fromSerialized(
            sentAliceDistributionMessage.serialize());

    final aliceDistributionMessage =
        await aliceSessionBuilder.create(aliceName);

    await bobSessionBuilder.process(aliceName, aliceDistributionMessage);

    final ciphertexts = [];

    for (var i = 0; i < 100; i++) {
      ciphertexts.add(await aliceGroupCipher
          .encrypt(Uint8List.fromList(utf8.encode('up the punks'))));
    }

    while (ciphertexts.isNotEmpty) {
      final index = _randomInt() % ciphertexts.length;
      final ciphertext = ciphertexts.removeAt(index);
      final plaintext = await bobGroupCipher.decrypt(ciphertext);

      assert(utf8.decode(plaintext) == 'up the punks');
    }
  });

  test('testEncryptNoSession', () async {
    final aliceStore = InMemorySenderKeyStore();
    final aliceGroupCipher = GroupCipher(
        aliceStore,
        SenderKeyName(
            'coolio groupio', SignalProtocolAddress('+10002223333', 1)));
    try {
      await aliceGroupCipher
          .encrypt(Uint8List.fromList(utf8.encode('up the punks')));
      throw AssertionError('Should have failed!');
    } on NoSessionException {
      // good
    }
  });

  test('testTooFarInFuture', () async {
    final aliceStore = InMemorySenderKeyStore();
    final bobStore = InMemorySenderKeyStore();

    final aliceSessionBuilder = GroupSessionBuilder(aliceStore);
    final bobSessionBuilder = GroupSessionBuilder(bobStore);

    final aliceName = GROUP_SENDER;

    final aliceGroupCipher = GroupCipher(aliceStore, aliceName);
    final bobGroupCipher = GroupCipher(bobStore, aliceName);

    final aliceDistributionMessage =
        await aliceSessionBuilder.create(aliceName);

    await bobSessionBuilder.process(aliceName, aliceDistributionMessage);

    for (var i = 0; i < 2001; i++) {
      await aliceGroupCipher
          .encrypt(Uint8List.fromList(utf8.encode('up the punks')));
    }

    final tooFarCiphertext = await aliceGroupCipher
        .encrypt(Uint8List.fromList(utf8.encode('notta gonna worka')));
    try {
      await bobGroupCipher.decrypt(tooFarCiphertext);
      throw AssertionError('Should have failed!');
    } on InvalidMessageException {
      // good
    }
  });

  test('testMessageKeyLimit', () async {
    final aliceStore = InMemorySenderKeyStore();
    final bobStore = InMemorySenderKeyStore();

    final aliceSessionBuilder = GroupSessionBuilder(aliceStore);
    final bobSessionBuilder = GroupSessionBuilder(bobStore);

    final aliceName = GROUP_SENDER;

    final aliceGroupCipher = GroupCipher(aliceStore, aliceName);
    final bobGroupCipher = GroupCipher(bobStore, aliceName);

    final aliceDistributionMessage =
        await aliceSessionBuilder.create(aliceName);

    await bobSessionBuilder.process(aliceName, aliceDistributionMessage);

    final inflight = [];

    for (var i = 0; i < 2010; i++) {
      inflight.add(await aliceGroupCipher
          .encrypt(Uint8List.fromList(utf8.encode('up the punks'))));
    }

    await bobGroupCipher.decrypt(inflight[1000]);
    await bobGroupCipher.decrypt(inflight[inflight.length - 1]);

    try {
      await bobGroupCipher.decrypt(inflight[0]);
      throw AssertionError('Should have failed!');
    } on DuplicateMessageException {
      // good
    }
  });
}
