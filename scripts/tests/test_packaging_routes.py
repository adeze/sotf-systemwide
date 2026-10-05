"""Static regression checks for the relocated macOS and Docker routes."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]


class PackagingRouteTests(unittest.TestCase):
    @staticmethod
    def _commands_with_continuations(source: str, command: str) -> list[str]:
        lines = source.splitlines()
        found = []
        for index, line in enumerate(lines):
            if command not in line or line.lstrip().startswith("#"):
                continue
            block = [line]
            while block[-1].rstrip().endswith("\\") and index + len(block) < len(lines):
                block.append(lines[index + len(block)])
            found.append("\n".join(block))
        return found

    def test_hal_layout_is_copied_from_its_current_owner(self) -> None:
        recipe = (ROOT / "sotf-systemwide/builds/macos.just").read_text()
        owner_path = ROOT / "sotf-daw/crates/driver-hal/shared_memory_layout.json"

        self.assertTrue(owner_path.is_file())
        self.assertEqual(recipe.count('../sotf-daw/crates/driver-hal/shared_memory_layout.json'), 3)
        self.assertNotIn('"crates/driver-hal/shared_memory_layout.json"', recipe)

    def test_sotf_installer_aliases_forward_hal_modes(self) -> None:
        recipe = (ROOT / "sotf/builds/macos.just").read_text()

        self.assertIn("cd ../sotf-systemwide && ./scripts/build-systemwide.sh", recipe)
        self.assertIn("cd ../sotf-systemwide && ./scripts/build-systemwide.sh --no-hal", recipe)

    def test_docker_builds_and_mounts_use_the_aggregate_layout(self) -> None:
        recipe = (ROOT / "sotf/builds/cross.just").read_text()
        build_commands = self._commands_with_continuations(recipe, "docker build")
        run_commands = self._commands_with_continuations(recipe, "docker run")

        self.assertGreater(len(build_commands), 0)
        self.assertGreater(len(run_commands), 0)
        self.assertTrue(all(re.search(r"\s\.\.\s*$", command) for command in build_commands))
        self.assertTrue(all('"$(pwd)/..":/workspace' in command for command in run_commands))
        self.assertTrue(all("/workspace/sotf" in command for command in run_commands))

    def test_dockerfiles_leave_cargo_building_to_the_mounted_workspace(self) -> None:
        dockerfiles = list((ROOT / "sotf/builds").rglob("Dockerfile*"))
        self.assertGreater(len(dockerfiles), 0)

        for dockerfile in dockerfiles:
            with self.subTest(dockerfile=dockerfile.relative_to(ROOT)):
                text = dockerfile.read_text()
                self.assertNotIn("COPY . .", text)
                self.assertNotRegex(text, r"(?m)^RUN cargo build\b")
                self.assertIn("RUSTUP_TOOLCHAIN=1.99.0", text)
                if "test-linux-arm64" not in dockerfile.name:
                    self.assertIn("1.99.0", text)

    def test_systemwide_linux_gate_builds_with_the_full_sibling_tree(self) -> None:
        recipe = (ROOT / "sotf-systemwide/builds/systemwide.just").read_text()
        dockerfile = (ROOT / "sotf/builds/systemwide/Dockerfile.test-linux-arm64").read_text()

        recipe_cwd = ROOT / "sotf-systemwide"
        mounted_root = (recipe_cwd / "..").resolve()
        docker_context = (recipe_cwd / "..").resolve()
        dockerfile_path = (recipe_cwd / "../sotf/builds/systemwide/Dockerfile.test-linux-arm64").resolve()

        self.assertIn("project_root=$(cd .. && pwd -P)", recipe)
        self.assertIn("--file ../sotf/builds/systemwide/Dockerfile.test-linux-arm64", recipe)
        self.assertIn("\n\t\t..\n", recipe)
        self.assertIn('"$project_root:/workspace:ro"', recipe)
        self.assertIn("--workdir /workspace/sotf-systemwide", recipe)
        self.assertEqual(mounted_root, ROOT.resolve())
        self.assertEqual(docker_context, ROOT.resolve())
        self.assertEqual(dockerfile_path, ROOT / "sotf/builds/systemwide/Dockerfile.test-linux-arm64")
        for sibling in ("sotf", "sotf-daw", "sotf-systemwide", "gpui-toolkit", "autoeq"):
            self.assertTrue((mounted_root / sibling).is_dir(), sibling)
        self.assertIn("FROM --platform=linux/arm64 ubuntu:24.04", dockerfile)
        self.assertIn("libasound2-dev", dockerfile)
        self.assertIn("ENV RUSTUP_TOOLCHAIN=1.99.0", dockerfile)


if __name__ == "__main__":
    unittest.main()
