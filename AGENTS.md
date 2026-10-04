# Tally working instructions

## User boundaries

- Do not run Git commands, read or modify `.git`, commit, or push. The user manages Git.
- Preserve personal `.tally` files, iCloud documents, app preferences, and financial data. Use isolated fictional data for testing.

## App copies after a patch

The user calls the official App Store installation **Alpha** and every development, test, or manually installed copy **Beta**. Alpha and Beta describe installation provenance, not prerelease channels or version numbers.

After each patch has been submitted to App Store review, remove the Beta installations before reporting the task complete. This is a standing user instruction, including simulator installs, temporary build products, earlier development backups, and extracted verification app bundles. Rebuild and reinstall only when the next patch requires them.

1. Identify Alpha by its App Store receipt and Apple Mac OS Application Signing signature. Preserve that exact app and its existing data. Do not identify Alpha from a filename or version number alone.
2. Quit running Beta copies gracefully before removing them. Never force quit a document window or delete its data as part of installation cleanup.
3. Remove non-App-Store Tally app bundles and their test runners from user Applications, temporary build folders, Xcode build products, and simulator installations. Use `simctl uninstall` for simulators; restore each simulator's previous boot state.
4. Keep release evidence, uploaded `.ipa`/`.pkg` packages, symbols, and submission records. Store Xcode release archives as verified compressed archives, then remove their expanded folders so they do not expose extra searchable `.app` bundles. Remove expanded package-verification copies after verification.
5. Unregister the exact removed or obsolete Tally paths from Launch Services and register Alpha. Do not reset Launch Services globally or remove Apple-managed iPhone Mirroring caches.
6. Verify that filesystem and Spotlight results have only Alpha as an existing Tally app, that macOS application lookup returns only Alpha, and that its receipt, executable, and signature remain intact. Record the cleanup and final verification in `Release`.

Leave source code, product screenshots, personal documents, and Git untouched by this cleanup. After testing or building recreates any Beta, repeat the cleanup after the submission.
