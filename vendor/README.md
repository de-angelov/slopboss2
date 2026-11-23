The FunScript tarball is built from github.com/de-angelov/funscript commit
`14d543b` (package version 0.2.3). It is checked in because the compiler is not
published as a versioned package and its Git source does not contain built `dist`.

SHA-256: `ac10abb1af4e55f19a05429ed225e0da6f3f8645dba7e6df5819c00709a59bd9`

To update it, check out the desired FunScript revision, install its dependencies,
run `npm run build`, then `npm pack`, copy the tarball here, update the dependency
in `package.json`, and regenerate `bun.lock`. Run `bun run check` and the tests.
