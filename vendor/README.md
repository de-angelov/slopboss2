The FunScript tarball is built from github.com/de-angelov/funscript commit
`adbf91a` (package version 0.2.3). It is checked in because the compiler is not
published as a versioned package and its Git source does not contain built `dist`.

SHA-256: `94f8e17d4a8251426d0f65f147e81fabed7562ea5c8e34444e9c746942e62fed`

To update it, check out the desired FunScript revision, install its dependencies,
run `npm run build`, then `npm pack`, copy the tarball here, update the dependency
in `package.json`, and regenerate `bun.lock`. Run `bun run check` and the tests.
