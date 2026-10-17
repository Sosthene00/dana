import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:danawallet/data/models/bip353_address.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/repositories/contacts_repository.dart';
import 'package:danawallet/repositories/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Seeded via raw db.insert(...) so the row bypasses Contact.toMap/addContact:
// the finding is about a legacy bad row already sitting in the database,
// exactly what a real install can hold from pre-validation builds.
const _badCode = 'SP1QOURS-GARBAGE';
const _goodCode1 =
    'sp1qq2xewwk5u02gxxurdzr6r6jerelncw82rlyvw2kpggxt3pum4kp6yq62utdcljdtmxpy3vs7c940hvjuzedhhsf7h2y5lflk7zp2xhgz3vryqw4n';
const _goodCode2 =
    'tsp1qq2d4vvramh9n3qrg5kaac7mjwdhfs402hg2msphmxuq3xqnw7hyj5qu9y636sf85v6uekr3vt3dcrzva64af9wct25y3wj0y4dgavjcp2uwsljny';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await RustLib.init();
    // Stale on-disk databases poison later runs; DatabaseHelper resolves
    // $HOME/.dana on linux, the ffi fallback lives under .dart_tool.
    final home = Platform.environment['HOME'] ?? '.';
    for (final p in [
      '$home/.dana/dana.db',
      '.dart_tool/sqflite_common_ffi/databases/dana.db',
    ]) {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    }
  });

  tearDownAll(() async => DatabaseHelper.instance.close());

  group('contacts list survives an unparseable payment-code row', () {
    late Database db;
    late int badId;

    setUp(() async {
      db = await DatabaseHelper.instance.database;
      await db.delete('contact_fields');
      await db.delete('contacts');
      await db.insert('contacts', {
        'id': 1,
        'name': 'Alice',
        'bip353Address': 'alice@dana.example',
        'paymentCode': _goodCode1,
      });
      await db.insert('contacts', {
        'id': 2,
        'name': 'Bob',
        'paymentCode': _goodCode2,
      });
      badId = await db.insert('contacts', {
        'id': 3,
        'name': 'Corrupt',
        'bip353Address': 'carol@dana.example',
        'paymentCode': _badCode,
      });
    });

    test('getAllContacts (no custom fields) returns good rows, no throw',
        () async {
      final contacts =
          await ContactsRepository.instance.getAllContacts(loadCustomFields: false);
      expect(contacts.map((c) => c.name), ['Alice', 'Bob']);
      // Quarantine must delete ONLY the bad row: collateral is a data-loss bug.
      final survivors = await db.query('contacts');
      expect(survivors.map((r) => r['id']).toList()..sort(), [1, 2]);
    });

    test('getAllContacts (with custom fields) returns good rows, no throw',
        () async {
      final contacts =
          await ContactsRepository.instance.getAllContacts(loadCustomFields: true);
      expect(contacts.length, 2);
      expect(contacts.map((c) => c.paymentCode.encode()).toSet(),
          {_goodCode1, _goodCode2});
      final survivors = await db.query('contacts');
      expect(survivors.length, 2);
    });

    test('getContact on the bad row returns null instead of throwing',
        () async {
      final contact = await ContactsRepository.instance.getContact(badId);
      expect(contact, isNull);
      // The good single-row path stays intact.
      final good = await ContactsRepository.instance.getContact(1);
      expect(good!.paymentCode.encode(), _goodCode1);
    });

    test(
        'getContactByBip353Address on the bad row returns null instead of throwing',
        () async {
      final addr = Bip353Address.fromString('carol@dana.example');
      // Probe first: prove the repo's own query shape can actually see the row,
      // so the expectation is not satisfied vacuously by a no-match query.
      final probe = await db.query('contacts',
          where: 'bip353Address = ?', whereArgs: [addr.toString()]);
      expect(probe.length, 1);
      final contact =
          await ContactsRepository.instance.getContactByBip353Address(addr);
      expect(contact, isNull);
    });
  });
}
