# Changelog

## [0.2.0] - 2026-06-02

- revert: roll back bogus v0.1.2, v1.0.0, v1.1.0 release commits
- chore: release v1.1.0
- chore: release v1.0.0
- chore: release v0.1.2
- fix(vm): make findAll linear by stopping matchAt when no threads remain (#8)
- fix(analyzer): don't reject bounded outers wrapping a quantifier (#3)
- chore: ignore pantry directory
- chore(ci): bump actions/checkout to v6, actions/cache to v5
- chore: refresh bun.lock and apply pickier --fix
- test: link libc for mod_tests so c_api.zig's c_allocator compiles
- ci: switch to mlugg/setup-zig, pin to 0.17.0-dev.56+a8226cd53
- refactor: migrate library sources to zig 0.17-dev APIs
- fix: use bare identifier for package name (Zig 0.15+ compat)

All notable changes to this project will be documented in this file.

