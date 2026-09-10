#!/usr/bin/env python3

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "convert_to_edm4hep.sh"


class ConvertToEdm4hepTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        converter = self.bin / "delphiRun"
        converter.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$@\" >\"$FAKE_CONVERTER_ARGS\"\n"
            "printf '%s\\n' \"$DELPHI_INPUT\" \"$DELPHI_INPUT_MODE\" "
            "\"$DELPHI_OUTPUT\" \"$DELPHI_CONVERSION_PASS\" "
            "\"$DELPHI_IS_REAL_DATA\" \"$DELPHI_MAX_EVENTS\" "
            ">\"$FAKE_CONVERTER_ENV\"\n"
            "printf output >\"$DELPHI_OUTPUT\"\n"
        )
        checker = self.bin / "delphi_btag_check"
        checker.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" >\"$FAKE_CHECKER_ARGS\"\n"
        )
        converter.chmod(0o755)
        checker.chmod(0o755)
        self.converter_args = self.root / "converter.args"
        self.converter_env = self.root / "converter.env"
        self.checker_args = self.root / "checker.args"
        self.env = os.environ | {
            "FAKE_CONVERTER_ARGS": str(self.converter_args),
            "FAKE_CONVERTER_ENV": str(self.converter_env),
            "FAKE_CHECKER_ARGS": str(self.checker_args),
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), "--edmbin", str(self.bin), *args],
            text=True,
            capture_output=True,
            env=self.env,
        )

    def test_local_simulation_input_and_checker(self) -> None:
        source = self.root / "simana.sdst"
        source.write_text("sdst")
        output = self.root / "out.root"
        result = self.run_script(
            "--input", str(source), "--output", str(output),
            "--sample", "mc", "-n", "7",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.converter_args.read_text().splitlines(),
            [str(REPO / "steering" / "delphi_convert_cfg.py")],
        )
        self.assertEqual(
            self.converter_env.read_text().splitlines(),
            [str(source), "file", str(output), "sdst", "false", "7"],
        )
        self.assertEqual(
            self.checker_args.read_text().splitlines(),
            ["--source", "sDST", str(output), "mc"],
        )

    def test_nickname_routes_to_converter(self) -> None:
        output = self.root / "nickname.root"
        result = self.run_script(
            "--nickname", "short94_c2/c1-10", "--output", str(output),
            "--no-check",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.converter_env.read_text().splitlines(),
            ["short94_c2/c1-10", "nickname", str(output), "sdst", "false", "-1"],
        )

    def test_pdl_routes_to_converter(self) -> None:
        pdl = self.root / "input.pdl"
        pdl.write_text("FAT = short94_c2\n")
        output = self.root / "pdl.root"
        result = self.run_script(
            "--pdl", str(pdl), "--output", str(output), "--no-check",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.converter_env.read_text().splitlines(),
            [str(pdl), "pdl", str(output), "sdst", "false", "-1"],
        )

    def test_data_sample_sets_real_data(self) -> None:
        source = self.root / "simana.sdst"
        source.write_text("sdst")
        output = self.root / "data.root"
        result = self.run_script(
            "--input", str(source), "--output", str(output),
            "--sample", "data", "--no-check",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.converter_env.read_text().splitlines()[4], "true")

    def test_rejects_multiple_input_modes(self) -> None:
        source = self.root / "simana.sdst"
        source.write_text("sdst")
        result = self.run_script(
            "--input", str(source), "--nickname", "short94_c2",
            "--output", str(self.root / "out.root"),
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("only one", result.stderr)


if __name__ == "__main__":
    unittest.main()
