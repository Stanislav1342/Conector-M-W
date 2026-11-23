"""Start Conector-M-W Receiver in an interactive terminal."""

import argparse
import sys

from . import Receiver


def main(argv=None):
    parser = argparse.ArgumentParser(description="Run the Conector-M-W Windows receiver.")
    parser.add_argument("--manual", action="store_true", help="show manual setup details including the private access code")
    args = parser.parse_args(argv)
    try:
        with Receiver() as receiver:
            if args.manual:
                print(receiver.connection_details(), flush=True)
                print("Enter refreshes the details; Ctrl+C stops.", flush=True)
                while True:
                    input()
                    print(receiver.connection_details(), flush=True)
            print(f"Conector-M-W pairing code: {receiver.pairing_code}", flush=True)
            print("Choose «Найти ПК в сети» in Conector-M-W on Mac. Enter renews the code; Ctrl+C stops.", flush=True)
            while True:
                input()
                print(f"Conector-M-W pairing code: {receiver.new_pairing_code()}", flush=True)
    except (KeyboardInterrupt, EOFError):
        return 0
    except (OSError, RuntimeError) as error:
        print(f"Conector-M-W Receiver: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
