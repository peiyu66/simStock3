import sqlite3
import tempfile
import unittest
from pathlib import Path
from candidate_fullstress_summary import negative_balances


class NegativeBalanceTests(unittest.TestCase):
    def test_scan_ignores_roundoff_but_catches_unflagged_empty_and_held(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.store'
            db = sqlite3.connect(path)
            db.executescript('''
                CREATE TABLE ZSTOCK (Z_PK INTEGER, ZSID TEXT, ZSNAME TEXT);
                CREATE TABLE ZTRADE (ZSTOCK INTEGER, ZSIMQTYINVENTORY REAL,
                    ZSIMAMTBALANCE REAL, ZDATETIME REAL);
                INSERT INTO ZSTOCK VALUES (1, 'A', 'Empty'), (2, 'B', 'Held'), (3, 'C', 'Clean');
                INSERT INTO ZTRADE VALUES
                    (1,0,-73598,0), (1,0,-73598,86400), (1,0,0,172800),
                    (2,10,-2,0), (3,0,-0.0000001,0), (3,0,1,86400);
            ''')
            db.close()
            rows = negative_balances(path)
            self.assertEqual([r['stock_id'] for r in rows], ['A', 'B'])
            self.assertEqual(rows[0]['negative_rows'], 2)
            self.assertEqual(rows[0]['empty_rows'], 2)
            self.assertEqual(rows[0]['minimum_balance'], -73598)
            self.assertEqual(rows[0]['first_date'], '2001-01-01')
            self.assertEqual(rows[0]['last_date'], '2001-01-02')
            self.assertEqual(rows[1]['empty_rows'], 0)

    def test_missing_store_is_not_silently_created(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'absent.store'
            with self.assertRaises(sqlite3.OperationalError):
                negative_balances(path)
            self.assertFalse(path.exists())


if __name__ == '__main__':
    unittest.main()
