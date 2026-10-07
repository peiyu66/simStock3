import unittest
from l_entry_delay_p04 import release

class Controls(unittest.TestCase):
    def test_first_release_not_best_future_price(self):
        r=release([False,False],[101,90],[1,2],100,False)
        self.assertEqual((r['offset'],r['priceClass']),(1,'higher'))
    def test_missing_before_release_not_confirmed_first(self):
        self.assertEqual(release([None,False],[99,98],[1,2],100,False)['status'],'first-release-uncertain')
    def test_equal_not_lower_and_reactivation(self):
        r=release([False,True],[100,90],[1,2],100,False)
        self.assertEqual(r['priceClass'],'equal');self.assertTrue(r['reactivatedLater'])
    def test_complete_vs_truncated_and_s_unknown(self):
        self.assertEqual(release([True]*10,[90]*10,list(range(10)),100,True)['status'],'persisted-ten-days')
        self.assertEqual(release([True],[90],[1],100,False)['status'],'truncated-no-release')
        self.assertEqual(release([False],[90],[1],100,True,True)['status'],'candidate-S-unknown')

if __name__=='__main__':unittest.main(verbosity=2)
