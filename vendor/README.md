The FunScript tarball is built from github.com/de-angelov/funscript commit
`87182cf` (package version 0.2.3). It is checked in because the compiler is not
published as a versioned package and its Git source does not contain built `dist`.

SHA-256: `797f7374b2c347687a2c15f6379404408af68e5ec7d7d40bc5a3326cd13d07bd`

To update it, check out the desired FunScript revision, install its dependencies,
run `npm run build`, then `npm pack`, copy the tarball here, update the dependency
in `package.json`, and regenerate `bun.lock`. Run `bun run check` and the tests.
