/*
 * Copyright (C) 2011 Daiki Ueno <ueno@unixuser.org>
 * Copyright (C) 2011 Red Hat, Inc.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
using Gee;

namespace Skk {
    public delegate int64 GetTime ();

    /**
     * A key event filter implementing NICOLA (thumb shift) input
     */
    public class NicolaKeyEventFilter : KeyEventFilter {
        static int64 get_time () {
            var tv = TimeVal ();
            return (((int64) tv.tv_sec) * 1000000) + tv.tv_usec;
        }

        public GetTime get_time_func = get_time;
        public int64 timeout = 100000;
        public int64 overlap = 50000;
        public int64 maxwait = 10000000;

        static const string[] SPECIAL_DOUBLES = {
            "[fj]", "[gh]", "[dk]", "[LR]"
        };
        public string[] special_doubles;

        class TimedEntry<T> {
            public T data;
            public int64 time;

            public TimedEntry (T data, int64 time) {
                this.data = data;
                this.time = time;
            }
        }

        LinkedList<TimedEntry<KeyEvent>> pending = new LinkedList<TimedEntry<KeyEvent>> ();

        // we can't use normal constructor here since KeyEventFilter
        // is constructed with Object.new (type).
        construct {
            special_doubles = SPECIAL_DOUBLES;
        }

        static bool is_char (KeyEvent key) {
            return key.code != 0;
        }

        static bool is_lshift (KeyEvent key) {
            return key.name == "lshift";
        }

        static bool is_rshift (KeyEvent key) {
            return key.name == "rshift";
        }

        static bool is_shift (KeyEvent key) {
            return is_lshift (key) || is_rshift (key);
        }

        static string get_special_double_name (KeyEvent a, KeyEvent b) {
            if (is_shift (a) && is_shift (b)) {
                return "[LR]";
            } else if (is_char (a) && is_char (b)) {
                unichar ac, bc;
                if (a.code < b.code) {
                    ac = a.code;
                    bc = b.code;
                } else {
                    ac = b.code;
                    bc = a.code;
                }
                return @"[$ac$bc]";
            } else {
                return_val_if_reached (null);
            }
        }

        KeyEvent? queue (KeyEvent key, int64 time, out int64 wait) {
            // press/release a same key
            if ((key.modifiers & ModifierType.RELEASE_MASK) != 0) {
                if (pending.size > 0 && pending.get (0).data.base_equal (key)) {
                    var entry = pending.get (0);
                    wait = get_next_wait (key, time);
                    pending.clear ();
                    return entry.data;
                }
            }
            // ignore key repeat
            else {
                if (pending.size > 0 && pending.get (0).data.base_equal (key)) {
                    pending.get (0).time = time;
                    wait = get_next_wait (key, time);
                    return key;
                }
                else {
                    if (pending.size > 2) {
                        var iter = pending.list_iterator ();
                        iter.last ();
                        do {
                            iter.remove ();
                        } while (pending.size > 2 && iter.previous ());
                    }
                    pending.insert (0, new TimedEntry<KeyEvent> (key, time));
                }
            }
            wait = maxwait;
            return null;
        }

        int64 get_next_wait (KeyEvent key, int64 time) {
            if (pending.size > 0) {
                var iter = pending.list_iterator ();
                iter.last ();
                do {
                    var entry = iter.get ();
                    if (time - entry.time > timeout) {
                        iter.remove ();
                    }
                } while (iter.previous ());
            }
            if (pending.size > 0) {
                return timeout - (time - pending.last ().time);
            } else {
                return maxwait;
            }
        }

        KeyEvent? dispatch_single (int64 time) {
            var entry = pending.peek ();
            if (time - entry.time > timeout) {
                pending.clear ();
                return entry.data;
            }
            return null;
        }

        void apply_shift (KeyEvent s, KeyEvent c) {
            if (s.name == "lshift") {
                c.modifiers |= ModifierType.LSHIFT_MASK;
            } else if (s.name == "rshift") {
                c.modifiers |= ModifierType.RSHIFT_MASK;
            }
        }

        KeyEvent? dispatch (int64 time) {
            if (pending.size == 3) {
                var b = pending.get (0);
                var s = pending.get (1);
                var a = pending.get (2);
                var t1 = s.time - a.time;
                var t2 = b.time - s.time;
                if (t1 <= t2) {
                    pending.clear ();
                    pending.offer_head (b);
                    var r = dispatch_single (time);
                    apply_shift (s.data, a.data);
                    forward (a.data);
                    return r;
                } else {
                    pending.clear ();
                    apply_shift (s.data, b.data);
                    forward (a.data);
                    return b.data;
                }
            } else if (pending.size == 2) {
                var b = pending.get (0);
                var a = pending.get (1);
                if (b.time - a.time > overlap) {
                    pending.clear ();
                    pending.offer_head (b);
                    var r = dispatch_single (time);
                    forward (a.data);
                    return r;
                } else if ((is_char (a.data) && is_char (b.data)) ||
                           (is_shift (a.data) && is_shift (b.data))) {
                    // skk-nicola uses some combinations of 2 character
                    // keys ([fj], [gh], etc.) and 2 shift keys ([LR]).
                    var name = get_special_double_name (b.data, a.data);
                    if (name in special_doubles) {
                        pending.clear ();
                        return new KeyEvent (name,
                                             (unichar) 0,
                                             ModifierType.NONE);
                    } else {
                        pending.clear ();
                        pending.offer_head (b);
                        var r = dispatch_single (time);
                        forward (a.data);
                        return r;
                    }
                } else if (time - a.time > timeout) {
                    pending.clear ();
                    if (is_shift (b.data)) {
                        apply_shift (b.data, a.data);
                        return a.data;
                    } else {
                        apply_shift (a.data, b.data);
                        return b.data;
                    }
                }
            } else if (pending.size == 1) {
                return dispatch_single (time);
            }

            return null;
        }

        void forward (KeyEvent key) {
            forwarded (key);
        }

        bool timeout_func () {
            int64 time = get_time_func ();
            var r = dispatch (time);
            if (r != null) {
                forward (r);
            }
            return false;
        }

        uint timeout_id = 0;

        /**
         * {@inheritDoc}
         */
        public override KeyEvent? filter_key_event (KeyEvent key) {
            KeyEvent? output = null;
            int64 time;
            if ((key.modifiers & ModifierType.USLEEP_MASK) != 0) {
                Thread.usleep ((long) int.parse (key.name));
                time = get_time_func ();
            } else {
                time = get_time_func ();
                int64 wait;
                output = queue (key, time, out wait);
                if (wait > 0) {
                    if (timeout_id > 0) {
                        Source.remove (timeout_id);
                    }
                    timeout_id = Timeout.add ((uint) wait, timeout_func);
                }
            }
            if (output == null) {
                output = dispatch (time);
            }
            return output;
        }

        public override void reset () {
            pending.clear ();
        }
    }
}
