# Contributing to Plume

Thanks for taking an interest in Plume. Bug reports, ideas and pull requests are welcome.

## Before you start

- **Bugs and ideas:** [open an issue](https://github.com/vikramgulia/plume/issues/new/choose). Check the existing issues first.
- **Bigger changes** (a new feature, a redesign, anything touching recording or transcription): open an issue and talk it through before writing code, so your time isn't wasted.
- **Security problems:** don't open a public issue. See [SECURITY.md](SECURITY.md).

## Proposing a change

1. Fork the repository and create a branch from `main`.
2. Make your change, keeping it small and focused. One pull request should do one thing.
3. Run the tests: `bash scripts/test-plume.sh` (needs Xcode 26 and XcodeGen, see the README for setup).
4. Open a pull request against `main`. Say what changed and why, and how you tested it. Link the issue it fixes.

`main` is protected: every change goes through a pull request, CI must pass, and the maintainer reviews and merges.

## Guidelines

- Match the surrounding code's style and naming.
- Add or update tests for behavior you change.
- Keep Plume private by design: recordings, transcripts and voice profiles stay on the user's Mac. Changes that send data off the device won't be accepted unless they are clearly opt-in.
- Write clear commit messages: a short summary line, then what and why.

## License of contributions

Plume is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). By submitting a contribution you confirm that you wrote it (or have the right to submit it), and you agree that:

- it is licensed under the same license as the rest of the project, and
- the maintainer may also license the project, including your contribution, to others under separate commercial terms.

If you can't agree to that, please don't submit code, but issues and ideas are still very welcome.
