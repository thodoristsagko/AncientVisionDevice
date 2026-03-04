#!/usr/bin/env python3
"""
battery_life_estimator.py — M5StickC Plus 2 battery life estimator.

Estimates field deployment duration based on operating mode and duty cycle.

M5StickC Plus 2 specs:
  Battery  : 200 mAh Li-Po
  Idle     : ~35 mA  (BLE advertising, no DSP)
  Active   : ~80 mA  (BLE + IMU @ 200 Hz + DSP on phone)
  Deep DSP : ~110 mA (legacy firmware with FFT/DWT on device)

Usage:
  python scripts/battery_life_estimator.py
  python scripts/battery_life_estimator.py --capacity 200 --mode active
  python scripts/battery_life_estimator.py --capacity 200 --duty-cycle 0.3
"""

import argparse
import sys

# ---------------------------------------------------------------------------
# Power profiles (mA)
# ---------------------------------------------------------------------------

PROFILES = {
    "idle": {
        "mA": 35,
        "description": "BLE advertising only, IMU polling off",
    },
    "active": {
        "mA": 80,
        "description": "BLE connected + IMU @ 200 Hz (DSP on phone, v5.0 firmware)",
    },
    "dsp-on-device": {
        "mA": 110,
        "description": "Legacy: BLE + IMU + FFT/DWT/kurtosis on ESP32",
    },
    "low-power": {
        "mA": 22,
        "description": "Low-power mode: slow polling, reduced BLE interval",
    },
}

BATTERY_EFFICIENCY = 0.85    # Li-Po discharge efficiency factor
SAFETY_MARGIN = 0.10         # Reserve 10% capacity for safe shutdown


def estimate(capacity_mah, mode, duty_cycle):
    """Return a dict with estimated runtime values."""
    profile = PROFILES[mode]
    current_ma = profile["mA"]

    idle_ma = PROFILES["idle"]["mA"]
    effective_ma = duty_cycle * current_ma + (1.0 - duty_cycle) * idle_ma

    usable_mah = capacity_mah * BATTERY_EFFICIENCY * (1.0 - SAFETY_MARGIN)
    runtime_hours = usable_mah / effective_ma

    return {
        "mode": mode,
        "description": profile["description"],
        "capacity_mah": capacity_mah,
        "duty_cycle_pct": duty_cycle * 100,
        "effective_current_ma": round(effective_ma, 1),
        "usable_mah": round(usable_mah, 1),
        "runtime_hours": round(runtime_hours, 2),
        "runtime_minutes": round(runtime_hours * 60, 0),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Estimate M5StickC Plus 2 battery life for field deployment."
    )
    parser.add_argument(
        "--capacity", type=float, default=200.0,
        help="Battery capacity in mAh (default: 200 -- M5StickC Plus 2 stock)",
    )
    parser.add_argument(
        "--mode",
        choices=list(PROFILES.keys()) + ["all"],
        default="all",
        help="Operating mode (default: all -- show all modes)",
    )
    parser.add_argument(
        "--duty-cycle", type=float, default=1.0, dest="duty_cycle",
        help="Fraction of time in active mode 0.0-1.0 (default: 1.0 = always active)",
    )
    args = parser.parse_args()

    if not 0.0 <= args.duty_cycle <= 1.0:
        print("ERROR: --duty-cycle must be between 0.0 and 1.0", file=sys.stderr)
        return 1

    modes = list(PROFILES.keys()) if args.mode == "all" else [args.mode]

    print()
    print("AncientVision -- Battery Life Estimator")
    print("=" * 60)
    print("  Battery capacity : %.0f mAh" % args.capacity)
    print("  Efficiency factor: %.0f%%" % (BATTERY_EFFICIENCY * 100))
    print("  Safety reserve   : %.0f%%" % (SAFETY_MARGIN * 100))
    print("  Duty cycle       : %.0f%%" % (args.duty_cycle * 100))
    print()
    print("  %-20s  %7s  %7s  %8s  Description" % ("Mode", "mA eff", "Hours", "Minutes"))
    print("  %s  %s  %s  %s  %s" % ("-"*20, "-"*7, "-"*7, "-"*8, "-"*35))

    for mode in modes:
        r = estimate(args.capacity, mode, args.duty_cycle)
        print(
            "  %-20s  %7.1f  %7.2f  %8.0f  %s" % (
                r["mode"], r["effective_current_ma"],
                r["runtime_hours"], r["runtime_minutes"],
                r["description"]
            )
        )

    print()
    print("NOTE: Estimates assume constant temperature (25 C) and new battery.")
    print("      Real-world runtime is typically 15-25% lower in cold field conditions.")
    print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
