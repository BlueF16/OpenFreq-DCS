import sys
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from f14_ptt_probe import extract, changes, label
from udp_monitor import describe

class TestF14Tools(unittest.TestCase):
    def test_extract_native_ptt(self):
        p={'aircraft': {'name': 'F-14B'},'selected_tx_radio':1,'ptt_pressed':True,
           'cockpit':{'ptt_source':'heatblur_native_devices','native_ptt':{'uhf1':True,'uhf2':False,'ics':False,'ics_hot_mic':False}}}
        self.assertEqual(extract(p)['uhf1'],True)
        self.assertEqual(extract(p)['tx'],1)
        p['aircraft']['name']='FA-18C_hornet'
        self.assertIsNone(extract(p))
        p['aircraft']['name']='F-14B'
        p['cockpit']['native_ptt']=None
        self.assertIsNone(extract(p))

    def test_events(self):
        samples=[{'t_s':0, 'tx':None,'ptt':False},
                 {'t_s':0.1, 'tx':None,'ptt':False},
                 {'t_s':0.2, 'tx':1,'ptt':True},
                 {'t_s':0.3, 'tx':1,'ptt':True},
                 {'t_s':0.4, 'tx':None,'ptt':False}]
        self.assertEqual(len(changes(samples)),3)
        self.assertIn('UHF1',label({'tx':1,'ptt':True}))

    def test_monitor_f14(self):
        p={'aircraft':{'name':'F-14B'},'radios':[
           {'id':1,'name':'UHF1 ARC-159','frequency_hz':251000000,'modulation':'AM','power_on':True,'volume':0.8},
           {'id':2,'name':'UHF2 ARC-182','frequency_hz':124800000,'modulation':'FM','power_on':False,'volume':0.3}],
           'selected_tx_radio':0,'ptt_pressed':True,'cockpit':{
             'ptt_source':'heatblur_native_devices','native_ptt':{'uhf1':False,'uhf2':False,'ics':True,'ics_hot_mic':False}}}
        rendered=describe(p)
        self.assertIn('TX=ICS PTT=True',rendered)
        self.assertIn('251.000 MHz AM',rendered)
        self.assertIn('124.800 MHz FM',rendered)
        self.assertIn('PTT_STATE[UHF1=False',rendered)
        p['selected_tx_radio']=2
        rendered=describe(p)
        self.assertIn('WARNING: selected radio OFF',rendered)
        p['selected_tx_radio']=None
        p['ptt_pressed']=None
        self.assertIn('TX=None PTT=None',describe(p))

if __name__ == '__main__': unittest.main()
