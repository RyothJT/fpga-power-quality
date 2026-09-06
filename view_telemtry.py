import serial
import struct
import time

PORT = '/dev/ttyUSB1' 
BAUD = 115200

try:
    ser = serial.Serial(PORT, BAUD, timeout=1)
    print(f"--- Connected to {PORT} at {BAUD} baud ---")
except Exception as e:
    print(f"Error: Could not open {PORT}. {e}")
    exit(1)

print(f"{'STATUS':10} | {'V_RMS':5} | {'I_RMS':5} | {'P_AVG':5} | {'Q_AVG':5} | {'V_Q':5} | {'FREQ':6} | {'THD':5}")
print("-" * 85)

while True:
    byte = ser.read(1)
    if byte == b'\xaa':
        # Read the rest of the packet: 1 status + 14 data + 1 footer = 16 bytes
        data = ser.read(16)
        
        if len(data) == 16 and data[15] == 0x55:
            # 1. Extract Status (data[0])
            status_byte = data[0]
            lock_status = "LOCKED" if (status_byte & 0x01) else "UNLOCKED"
            
            # 2. Unpack the 14 bytes of signal data (data[1] through data[14])
            # Format: > (Big Endian)
            # H, H (Unsigned: V_rms, I_rms)
            # h, h, h (Signed: P_avg, Q_avg, V_q)
            # H, H (Unsigned: Freq, THD)
            vals = struct.unpack('>HHhhhHH', data[1:15])
            v_rms, i_rms, p_avg, q_avg, v_q, freq_raw, thd_raw = vals
            
            # 3. Convert to real units
            freq_hz = freq_raw / 256.0
            thd_pct = (thd_raw / 4096.0) * 100.0 if lock_status == "LOCKED" else 0.0
            
            # 4. Print everything
            print(f"{lock_status:10} | {v_rms:5d} | {i_rms:5d} | {p_avg:5d} | {q_avg:5d} | {v_q:5d} | {freq_hz:6.2f} | {thd_pct:5.2f}%")
            
        elif len(data) == 16:
            print(f"Sync Error: Expected 0x55 footer, got 0x{data[15]:02x}")
