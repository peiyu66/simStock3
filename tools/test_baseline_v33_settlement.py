"""Signed principal-return loss is valid; unfunded trading is not."""
import unittest
from audit_baseline_v33_risk import validate_settlement

class SettlementTests(unittest.TestCase):
    def setUp(self):
        self.previous = dict(ZSIMRULE='', ZSIMAMTBALANCE=11801281,
                             ZSIMQTYSELL=252, ZSIMINVESTTIMES=3)
        self.settlement = dict(ZSIMRULE='', ZSIMAMTBALANCE=-198719,
            ZSIMQTYBUY=0, ZSIMQTYSELL=0, ZSIMQTYINVENTORY=0,
            ZSIMAMTCOST=0, ZSIMAMTPROFIT=0, ZSIMINVESTBYUSER=0,
            ZSIMINVESTTIMES=1, ZROLLAMTPROFIT=-6198719)

    def check(self, row=None, previous=None, invested=-2, buy=0):
        return validate_settlement(row or self.settlement,
            previous or self.previous, 6000000, invested, buy)

    def test_loss_after_returning_additional_principal(self):
        self.assertTrue(self.check())

    def test_signed_residual_persists_without_trading(self):
        self.assertTrue(self.check(previous=self.settlement, invested=0))

    def test_reject_purchase_on_negative_residual(self):
        with self.assertRaises(AssertionError):
            self.check(dict(self.settlement, ZSIMQTYBUY=1), buy=50000)

    def test_reject_inventory_on_negative_residual(self):
        with self.assertRaises(AssertionError):
            self.check(dict(self.settlement, ZSIMQTYINVENTORY=1))

    def test_reject_unexplained_withdrawal(self):
        with self.assertRaises(AssertionError):
            self.check(previous=dict(self.previous, ZSIMQTYSELL=0))

    def test_reject_erased_cumulative_loss(self):
        with self.assertRaises(AssertionError):
            self.check(dict(self.settlement, ZROLLAMTPROFIT=0))

    def test_reject_unrecorded_funding(self):
        with self.assertRaises(AssertionError):
            self.check(dict(self.settlement, ZSIMAMTBALANCE=-100000),
                       previous=self.settlement, invested=0)

    def test_reject_purchase_exceeding_available_funds(self):
        with self.assertRaises(AssertionError):
            self.check(dict(self.settlement, ZSIMAMTBALANCE=10),
                       previous=dict(self.previous, ZSIMAMTBALANCE=100),
                       invested=0, buy=101)

if __name__ == '__main__':
    unittest.main()
