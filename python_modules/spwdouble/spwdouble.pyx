# noinspection PyUnresolvedReferences
import numpy as np
# noinspection PyUnresolvedReferences
cimport numpy as np
# noinspection PyUnresolvedReferences
from cython cimport view
import serial
import scipy.signal
import logging

isDebug = False


# noinspection PyPep8Naming
class spwdouble(object):
    def __init__(self):
        """initialize object data"""
        self.Enabled = 1
        self.chan_enabled = []

        self.jitter_count_down_thresh = 0
        self.jitter_count_down = 0
        self.jitter_time = 200. # in ms
        self.refractory_count_down_thresh = 0
        self.samples_for_average = 0
        self.refractory_count_down = 0
        self.refractory_time = 100. # time that the plugin will not react to trigger after one pulse
        self.double_count_down_thresh = 0
        self.double_count_down = 0
        self.double_time = 200.
        self.double_rate = 1. / 3.

        self.averaging_time_min = 10.
        self.averaging_time_max = 50.
        self.averaging_time_start = 20.
        self.averaging_time = self.averaging_time_start # in ms
        self.chan_in = 1
        self.chan_out = 0
        self.n_samples = 0
        self.chan_ripples = 1
        self.band_lo_min = 50.
        self.band_lo_max = 200.
        self.band_lo_start = 100.
        self.band_lo = self.band_lo_start

        self.band_hi_min = 100.
        self.band_hi_max = 500.
        self.band_hi_start = 300.
        self.band_hi = self.band_hi_start

        self.thresh_min = 5.
        self.thresh_max = 200.
        self.thresh_start = 30.
        self.threshold = self.thresh_start


        self.swing_thresh_min = 10.
        self.swing_thresh_max = 20000.
        self.swing_thresh_start = 1000.
        self.swing_thresh = self.swing_thresh_start

        self.SWINGING = 1
        self.NOT_SWINGING = 0
        self.swing_state = self.NOT_SWINGING
        self.swing_count_down_thresh = 0
        self.swing_count_down = 0
        self.swing_down_time = 2000. # time that it will be prevetned from firing after a swing event

        self.pulseNo = 0
        self.triggered = 0
        self.samplingRate = 0.
        self.polarity = 0
        self.filter_a = []
        self.filter_b = []
        self.arduino = None
        self.lfp_buffer_max_count = 1000
        self.lfp_buffer = np.zeros((self.lfp_buffer_max_count,))
        self.READY=1
        self.ARMED=2
        self.REFRACTORY=3
        self.FIRING = 4
        self.TRIGGERED2 = 5
        self.FIRING2 = 6
        self.state = self.READY
        logging.basicConfig(filename='spwdouble.log', format='%(asctime)s %(message)s', level=logging.DEBUG)

    def startup(self, nchans, srate, states):
        """to be run upon startup"""
        self.update_settings(nchans, srate)
        for chan in range(nchans):
            if not states[chan]:
                self.channel_changed(chan, False)

        self.Enabled = 1
        try:
            self.arduino = serial.Serial('/dev/ttyACM0', 57600)
        except (OSError, serial.serialutil.SerialException):
            print("Can't open Arduino")

    def plugin_name(self):
        """tells OE the name of the program"""
        return "spwdouble"

    def is_ready(self):
        """tells OE everything ran smoothly"""
        return self.Enabled

    def param_config(self):
        """return button, sliders, etc to be present in the editor OE side"""
        chan_labels = range(1,33)
        return (("toggle", "Enabled", True),
                ("int_set", "chan_in", chan_labels),
                ("float_range", "threshold", self.thresh_min, self.thresh_max, self.thresh_start),
                ("float_range", "swing_thresh", self.swing_thresh_min, self.swing_thresh_max, self.swing_thresh_start),
                ("float_range", "averaging_time", self.averaging_time_min, self.averaging_time_max, self.averaging_time_start))

    def spw_condition(self, n_arr):
        return (np.mean(n_arr[self.chan_out+1,:]) > self.threshold) and self.swing_state == self.NOT_SWINGING

    def stimulate(self):
        try:
            self.arduino.write(b'1')
        except AttributeError:
            print("Can't send pulse")
        self.pulseNo += 1
        print("generating pulse ", self.pulseNo)
        logging.debug('sending pulse')

    def new_event(self, events, code, channel=0, timestamp=None):
        if not timestamp:
            timestamp = self.n_samples
        events.append({'type': 3, 'sampleNum': timestamp, 'eventId': code, 'eventChannel': channel})

    def update_settings(self, nchans, srate):
        """handle changing number of channels and sample rates"""
        if srate != self.samplingRate:
            self.samplingRate = srate

            # noinspection PyTupleAssignmentBalance
            self.filter_b, self.filter_a = scipy.signal.butter(3,
                                                         (self.band_lo/(self.samplingRate/2), self.band_hi/(self.samplingRate/2)),
                                                         'pass')
            print(self.filter_a)
            print(self.filter_b)
            print(self.band_lo)
            print(self.band_hi)
            print(self.band_lo/(self.samplingRate/2))
            print(self.band_hi/(self.samplingRate/2))

        old_nchans = len(self.chan_enabled)
        if old_nchans > nchans:
            del self.chan_enabled[nchans:]
        elif len(self.chan_enabled) < nchans:
            self.chan_enabled.extend([True] * (nchans - old_nchans))

    def channel_changed(self, chan, state):
        """do something when channels are turned on or off in PARAMS tab"""
        self.chan_enabled[chan] = state

    def bufferfunction(self, n_arr):
        """Access to voltage data buffer. Returns events"""
        if isDebug:
            print("shape: ", n_arr.shape)
        events = []
        cdef int chan_in
        cdef int chan_out
        chan_in = self.chan_in - 1
        self.chan_out = self.chan_ripples

        self.n_samples = int(n_arr.shape[1])

        if self.n_samples == 0:
            return events

        # setting up count down thresholds in units of samples
        self.refractory_count_down_thresh =  self.refractory_time * self.samplingRate / 1000.
        self.double_count_down_thresh = self.double_time * self.samplingRate / 1000.
        self.swing_count_down_thresh = self.swing_down_time * self.samplingRate / 1000.
        self.jitter_count_down_thresh = self.jitter_time * self.samplingRate / 1000.
        self.samples_for_average = int(self.averaging_time * self.samplingRate / 1000.)

        signal_to_filter = np.hstack((self.lfp_buffer, n_arr[chan_in,:]))
        signal_to_filter = signal_to_filter - signal_to_filter[-1]
        filtered_signal = scipy.signal.lfilter(self.filter_b, self.filter_a, signal_to_filter)
        n_arr[self.chan_out,:] = filtered_signal[self.lfp_buffer.size:]
        self.lfp_buffer = np.append(self.lfp_buffer, n_arr[chan_in,:])
        if self.lfp_buffer.size > self.lfp_buffer_max_count:
            self.lfp_buffer = self.lfp_buffer[-self.lfp_buffer_max_count:]
        n_arr[self.chan_out+1,:] = np.fabs(n_arr[self.chan_out,:])
        n_arr[self.chan_out+2,:] = 5. *np.mean(filtered_signal[-self.samples_for_average:]) * np.ones((1,self.n_samples))


        # the swing detector state machine
        max_swing = np.max(np.fabs(n_arr[chan_in,:]))
        if self.swing_state == self.NOT_SWINGING:
            if max_swing > self.swing_thresh:
                self.swing_state = self.SWINGING
                self.swing_count_down = self.swing_count_down_thresh
                self.new_event(events, 6)
                logging.debug("SWINGING")
        else:
            self.swing_count_down -= self.n_samples
            if self.swing_count_down <= 0:
                self.swing_state = self.NOT_SWINGING
                logging.debug("NOT_SWINGING")


        if isDebug:
            print("Mean: ", np.mean(n_arr[self.chan_out+1,:]))
            print("done processing")

        #events
        # 1: pulse sent
        # 2: jittered, pulse_sent
        # 3: triggered, not enabled
        # 4: trigger armed, jittered
        # 5: terminating pulse
        # 6: swing detected
        # machines:
        # ENABLED vs. DISABLED vs. JITTERED
        # states:
        # READY, REFRACTORY, ARMED, FIRING
        # now w/ logging


        # finite state machine
        if self.state == self.READY:
            if self.spw_condition(n_arr):
                if self.Enabled:
                    logging.debug('got spw')
                    self.jitter_count_down = self.jitter_count_down_thresh
                    self.state = self.ARMED
                    logging.debug('ARMED')
                    self.new_event(events, 1, 1)
                else:
                    self.new_event(events, 3)
        elif self.state == self.ARMED:
            logging.debug('in ARMED with countdown %d', self.jitter_count_down)
            if self.jitter_count_down == self.jitter_count_down_thresh:
                self.new_event(events, 5, 1)
            self.jitter_count_down -= self.n_samples
            if self.jitter_count_down <= 0:
                self.stimulate()
                self.new_event(events, 2)
                self.state = self.FIRING
                logging.debug('FIRING')
                self.new_event(events, 1)
        elif self.state == self.FIRING:
            if np.random.random() < self.double_rate:
                self.double_count_down = self.double_count_down_thresh-1
                print('double')
                self.state = self.TRIGGERED2
                logging.debug('TRIGGERED2')
            else:
                self.refractory_count_down = self.refractory_count_down_thresh-1
                self.state = self.REFRACTORY
                logging.debug('REFRACTORY')
            self.new_event(events, 5)
        elif self.state == self.TRIGGERED2:
            self.double_count_down -= self.n_samples
            if self.double_count_down <= 0:
                self.stimulate()
                self.new_event(events, 1)
                self.state = self.FIRING2
                logging.debug('FIRING2')
        elif self.state == self.FIRING2:
            self.refractory_count_down = self.refractory_count_down_thresh-1
            self.state = self.REFRACTORY
            logging.debug('REFRACTORY')
            self.new_event(events, 5)
        elif self.state == self.REFRACTORY:
            self.refractory_count_down -= self.n_samples
            if self.refractory_count_down <= 0:
                self.state = self.READY
                logging.debug('READY')
        else:
            # checking for a leftover ARMED state
            self.state = self.READY
            logging.debug('READY')

        return events

    def handleEvents(self, eventType, sourceID, subProcessorIdx, timestamp, sourceIndex):
        """handle events passed from OE"""

    def handleSpike(self, electrode, sortedID, n_arr):
        """handle spikes passed from OE"""


pluginOp = spwdouble()

include '../plugin.pyx'
