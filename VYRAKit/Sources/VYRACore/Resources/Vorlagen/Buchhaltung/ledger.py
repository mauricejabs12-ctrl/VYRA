"""Entwicklungsbeispiel: kleines, transaktionales Journal in SQLite."""
from contextlib import contextmanager
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
import csv
import sqlite3
import uuid


def cents(value):
    """EUR exakt einlesen; mehr als zwei Nachkommastellen explizit ablehnen."""
    if isinstance(value, (float, bool)):
        raise ValueError("Geld bitte als Text oder Decimal angeben.")
    try:
        amount = Decimal(value)
        if not amount.is_finite() or amount != amount.quantize(Decimal('0.01')):
            raise ValueError("Betrag braucht hoechstens zwei Nachkommastellen.")
        result = int(amount * 100)
        if abs(result) > 100_000_000_000:
            raise ValueError("Betrag ist zu gross.")
        return result
    except (InvalidOperation, TypeError) as exc:
        raise ValueError("Ungueltiger Betrag.") from exc


class Ledger:
    def __init__(self, path):
        self.db = sqlite3.connect(str(path), isolation_level=None, timeout=10)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS entries(
                id TEXT PRIMARY KEY, booking_date TEXT NOT NULL,
                reference TEXT NOT NULL, description TEXT NOT NULL,
                import_key TEXT UNIQUE NOT NULL, created_at TEXT NOT NULL,
                reversal_of TEXT UNIQUE REFERENCES entries(id));
            CREATE TABLE IF NOT EXISTS lines(
                entry_id TEXT NOT NULL REFERENCES entries(id), position INTEGER NOT NULL,
                account TEXT NOT NULL, debit INTEGER NOT NULL, credit INTEGER NOT NULL,
                PRIMARY KEY(entry_id, position),
                CHECK(debit >= 0 AND credit >= 0),
                CHECK((debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0)));
            CREATE TABLE IF NOT EXISTS sealed(entry_id TEXT PRIMARY KEY REFERENCES entries(id));
            CREATE TRIGGER IF NOT EXISTS validate_seal BEFORE INSERT ON sealed BEGIN
                SELECT CASE WHEN (SELECT COUNT(*) FROM lines WHERE entry_id=NEW.entry_id)<2
                    OR (SELECT SUM(debit-credit) FROM lines WHERE entry_id=NEW.entry_id)!=0
                    THEN RAISE(ABORT, 'Buchung ist nicht ausgeglichen') END;
            END;
            CREATE TRIGGER IF NOT EXISTS no_late_lines BEFORE INSERT ON lines
                WHEN EXISTS(SELECT 1 FROM sealed WHERE entry_id=NEW.entry_id)
                BEGIN SELECT RAISE(ABORT, 'Buchung ist abgeschlossen'); END;
        ''')
        for table in ('entries', 'lines', 'sealed'):
            for action in ('UPDATE', 'DELETE'):
                self.db.execute('CREATE TRIGGER IF NOT EXISTS no_%s_%s BEFORE %s ON %s '
                                "BEGIN SELECT RAISE(ABORT, 'Nur Storno erlaubt'); END"
                                % (table, action.lower(), action, table))

    @contextmanager
    def transaction(self):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            yield
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise

    def _post(self, booking_date, reference, description, lines, import_key, reversal_of=None):
        booking_date = date.fromisoformat(booking_date).isoformat()
        reference, description, import_key = reference.strip(), description.strip(), import_key.strip()
        if not reference or not description or not import_key:
            raise ValueError('Belegreferenz, Beschreibung und Importschluessel sind erforderlich.')
        if len(reference) > 200 or len(description) > 2000 or len(import_key) > 200:
            raise ValueError('Text ist zu lang.')
        if len(lines) < 2 or len(lines) > 100:
            raise ValueError('Eine Buchung braucht 2 bis 100 Zeilen.')
        checked = []
        for account, debit, credit in lines:
            if not isinstance(account, str) or not account.strip() or len(account) > 80:
                raise ValueError('Ungueltiges Konto.')
            if type(debit) is not int or type(credit) is not int:
                raise ValueError('Soll und Haben muessen ganzzahlige Cent sein.')
            if debit < 0 or credit < 0 or (debit > 0) == (credit > 0):
                raise ValueError('Je Zeile genau einen positiven Soll- oder Habenbetrag angeben.')
            if max(debit, credit) > 100_000_000_000:
                raise ValueError('Betrag ist zu gross.')
            checked.append((account.strip(), debit, credit))
        if sum(x[1] - x[2] for x in checked) != 0:
            raise ValueError('Soll und Haben sind nicht ausgeglichen.')
        identity = uuid.uuid4().hex
        self.db.execute('INSERT INTO entries VALUES(?,?,?,?,?,?,?)',
                        (identity, booking_date, reference, description, import_key,
                         datetime.now(timezone.utc).isoformat(), reversal_of))
        self.db.executemany('INSERT INTO lines VALUES(?,?,?,?,?)',
                            [(identity, i, *line) for i, line in enumerate(checked)])
        self.db.execute('INSERT INTO sealed VALUES(?)', (identity,))
        return identity

    def post(self, booking_date, reference, description, lines, import_key=None):
        with self.transaction():
            return self._post(booking_date, reference, description, lines,
                              import_key or uuid.uuid4().hex)

    def reverse(self, identity, booking_date, reference):
        with self.transaction():
            entry = self.db.execute('SELECT * FROM entries WHERE id=?', (identity,)).fetchone()
            if entry is None:
                raise ValueError('Buchung wurde nicht gefunden.')
            rows = self.db.execute('SELECT account,credit,debit FROM lines WHERE entry_id=? '
                                   'ORDER BY position', (identity,)).fetchall()
            return self._post(booking_date, reference, 'Storno: ' + entry['description'],
                              [tuple(row) for row in rows], 'storno:' + identity, identity)

    def journal(self):
        return self.db.execute('SELECT e.id,e.booking_date,e.reference,e.description,'
                               'l.account,l.debit,l.credit,e.reversal_of FROM entries e '
                               'JOIN sealed s ON s.entry_id=e.id JOIN lines l ON l.entry_id=e.id '
                               'ORDER BY e.booking_date,e.created_at,e.id,l.position').fetchall()

    def export_csv(self, path):
        def cell(value):
            text = '' if value is None else str(value)
            # Tabellenprogramme sollen Belegtexte nicht als Formeln ausfuehren.
            return "'" + text if text.lstrip().startswith(('=', '+', '-', '@')) else text
        with open(path, 'x', encoding='utf-8-sig', newline='') as stream:
            writer = csv.writer(stream, delimiter=';')
            writer.writerow(('ID', 'Datum', 'Beleg', 'Beschreibung', 'Konto', 'Soll Cent',
                             'Haben Cent', 'Storno von'))
            writer.writerows([cell(v) for v in row] for row in self.journal())

    def backup(self, path):
        if Path(path).exists():
            raise FileExistsError(path)
        target = sqlite3.connect(str(path))
        try:
            self.db.backup(target)
        finally:
            target.close()

    def close(self):
        self.db.close()
