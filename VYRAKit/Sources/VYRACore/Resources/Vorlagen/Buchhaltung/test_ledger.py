import csv
from decimal import Decimal
from pathlib import Path
import sqlite3
import tempfile
import unittest
from ledger import Ledger, cents


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self.tmp.name)
        self.book = Ledger(self.folder / 'test.sqlite3')

    def tearDown(self):
        self.book.close()
        self.tmp.cleanup()

    def post(self, key='beleg-1'):
        return self.book.post('2026-12-31', 'B-1', 'Test', [('1200', 1234, 0), ('8400', 0, 1234)], key)

    def test_exact_money(self):
        self.assertEqual(cents('0.29'), 29)
        self.assertEqual(cents(Decimal('19.99')), 1999)
        for invalid in (0.29, True, '0.001', 'NaN', 'Infinity', 'kaputt'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                cents(invalid)

    def test_unbalanced_does_not_persist(self):
        with self.assertRaises(ValueError):
            self.book.post('2026-01-01', 'B', 'Test', [('1200', 100, 0), ('8400', 0, 90)])
        self.assertEqual(len(self.book.journal()), 0)

    def test_duplicate_import_rollback(self):
        self.post()
        with self.assertRaises(sqlite3.IntegrityError):
            self.post()
        self.assertEqual(len(self.book.journal()), 2)
        self.post('another')
        self.assertEqual(len(self.book.journal()), 4)

    def test_reversal_keeps_original_and_balances(self):
        identity = self.post()
        self.book.reverse(identity, '2027-01-01', 'S-1')
        rows = self.book.journal()
        self.assertEqual(len(rows), 4)
        for account in ('1200', '8400'):
            self.assertEqual(sum(row['debit'] - row['credit'] for row in rows if row['account'] == account), 0)
        with self.assertRaises(sqlite3.IntegrityError):
            self.book.reverse(identity, '2027-01-01', 'S-2')

    def test_journal_immutable(self):
        identity = self.post()
        for statement in ('DELETE FROM entries', 'UPDATE lines SET debit=1', 'DELETE FROM sealed'):
            with self.subTest(statement=statement), self.assertRaises(sqlite3.IntegrityError):
                self.book.db.execute(statement)
        with self.assertRaises(sqlite3.IntegrityError):
            self.book.db.execute('INSERT INTO lines VALUES(?,9,?,1,0)', (identity, '1200'))

    def test_invalid_date_and_amount(self):
        for lines in ([('1200', 1.2, 0), ('8400', 0, 1.2)], [('1200', -1, 0), ('8400', 0, -1)]):
            with self.assertRaises(ValueError):
                self.book.post('2026-01-01', 'B', 'Test', lines)
        with self.assertRaises(ValueError):
            self.book.post('2026-02-30', 'B', 'Test', [('1200', 1, 0), ('8400', 0, 1)])

    def test_csv_formula_and_backup(self):
        self.book.post('2026-01-01', '=1+1', '@SUM(A1)', [('1200', 1, 0), ('8400', 0, 1)])
        path = self.folder / 'export.csv'
        self.book.export_csv(path)
        with path.open(encoding='utf-8-sig', newline='') as stream:
            rows = list(csv.reader(stream, delimiter=';'))
        self.assertEqual(rows[1][2], "'=1+1")
        self.assertEqual(rows[1][3], "'@SUM(A1)")
        with self.assertRaises(FileExistsError):
            self.book.export_csv(path)
        backup = self.folder / 'backup.sqlite3'
        self.book.backup(backup)
        restored = Ledger(backup)
        try:
            self.assertEqual(len(restored.journal()), 2)
        finally:
            restored.close()


if __name__ == '__main__':
    unittest.main()
