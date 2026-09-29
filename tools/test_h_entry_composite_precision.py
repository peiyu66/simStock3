import unittest
import h_entry_composite_precision as q

def make(prices,hs=None,ls=None):
 hs=hs or [True]*len(prices);ls=ls or [False]*len(prices)
 return dict(sample='A',window=1,price=prices[0],eligibleLower10=any(v<prices[0] for v in prices[1:]),days=[dict(price=v,h=hs[i],l=ls[i]) for i,v in enumerate(prices)])
def score(path,signals,valid=None):
 sc=q.Screen([path]);m=sum(int(v)<<i for i,v in enumerate(signals));v=sum(int(x)<<i for i,x in enumerate(valid or [True]*len(signals)))
 return sc.calc(m,v)
class TimingTests(unittest.TestCase):
 def test_first_fill_not_best_price(self):
  z=score(make([100,102,90]),[1,0,0]);self.assertEqual((z['dearer'],z['good']),(1,0))
 def test_cheaper_but_not_qualified(self):
  z=score(make([100,90,102],hs=[1,0,1]),[1,0,0]);self.assertEqual(z['dearer'],1)
 def test_qualified_after_gate_release(self):
  z=score(make([100,102,90]),[1,1,0]);self.assertEqual(z['good'],1)
 def test_l_fallback_while_gate_persists(self):
  z=score(make([100,90],ls=[0,1]),[1,1]);self.assertEqual(z['good'],1)
 def test_same_day_l_is_not_delay(self):
  z=score(make([100,90],ls=[1,0]),[1,0]);self.assertEqual(z['sameDay'],1)
 def test_unknown_not_success(self):
  z=score(make([100,90]),[1,0],[1,0]);self.assertEqual((z['good'],z['unknown']),(0,1))
 def test_no_fill_not_dropped(self):
  z=score(make([100,90]),[1,1]);self.assertEqual((z['hits'],z['remaining']),(1,1))
 def test_day_ten_and_day_eleven(self):
  path=make([100]*10+[90,80]);z=score(path,[1]*10+[0,0]);self.assertEqual(z['good'],1)
  z=score(path,[1]*11+[0]);self.assertEqual(z['remaining'],1)
 def test_equal_not_cheaper(self):
  z=score(make([100,100]),[1,0]);self.assertEqual((z['equal'],z['good']),(1,0))
 def test_no_support_floor(self):
  z=score(make([100,99]),[1,0]);self.assertEqual((z['hits'],z['tier']),(1,2))
 def test_price_guard_absent(self):
  # A higher first eligible price is an actual failure, not secretly suppressed until price falls.
  z=score(make([100,110,70]),[1,0,0]);self.assertEqual(z['precision'],0)
 def test_cash_lots(self):
  self.assertFalse(q.cash_ok(100,100000));self.assertTrue(q.cash_ok(100,100143));self.assertFalse(q.cash_ok(100,100142))
if __name__=='__main__':unittest.main()
