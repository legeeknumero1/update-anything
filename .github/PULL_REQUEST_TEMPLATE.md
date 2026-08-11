## What this changes

<!-- And why the obvious approach was not the right one, if relevant. -->

## Checklist

- [ ] `./tests/run.sh` passes
- [ ] `shellcheck -S style update-anything.sh install.sh tests/run.sh completions/update-anything.bash` is clean
- [ ] bash 3.2 only — no associative arrays, `mapfile`, `${var,,}` or `local -n`
- [ ] No package manager is assumed present; it is detected first
- [ ] Anything destructive is opt-in, and a manager's own prompts are left interactive
- [ ] A test covers the behaviour this changes
