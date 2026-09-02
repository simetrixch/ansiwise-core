# ansiwise-core

Runs a declared program of steps against a machine, and can prove in advance what it would change.

The framework: model, domain, engine, config, steps, infrastructure. It knows nothing about what is
being deployed — a plugin brings all of that, and a check turns the tree red if any of it appears
here.

It is a library. The REST surface lives in the composition root, `ansiwise-cli`, which produces two
executables from it: `ansiwise`, which runs a declared program against a machine, and
`ansiwise-rest`, which serves the REST surface over an address or over a session's own pipes. Both
compose ONE plugin list, so the two cannot come to know different steps.


Runs a declared program of steps against a machine, and can prove in advance what it would change.

Configuration management tools describe a desired state and then hope the run matches it. This one
answers a narrower question honestly: **what will this do to this machine, before it does it** — and
it makes the answer structural rather than a promise.

```
ansiwise deploy-cluster --mode test    # measures the machine and prints the real plan for it
ansiwise deploy-cluster --mode dry     # says what would change, and where it stops being reversible
ansiwise deploy-cluster --mode run     # refuses without a green dry run for this exact input
```

## What makes the dry run trustworthy

**Four ports are the only way any code reaches outside** — `Shell`, `Files`, `Http` and `Clock`.
Nothing else touches a process, a file or a socket, and a check fails the build if it tries.

Two things follow, and neither depends on anybody remembering:

- **A dry run cannot mutate.** The engine calls `plan()` rather than `apply()`, *and* the planning
  ports throw on anything a step did not declare it observes. Two independent mechanisms, because one
  of them is a policy and the other is a wall.
- **Every command, every write and every request is recorded**, through one redactor, because there
  is no other way out. A run record is a file on disk naming each step, its source `path:line`, its
  verdict, and everything that reached the machine.

**Success is a checked postcondition, not an exit code.** After `apply()` the step's own `check()`
runs again; `Satisfied` is what proves it worked. A command that returned zero and changed nothing
is the failure this exists to catch, because it looks like success everywhere else.

**Reversibility is forced by the compiler.** `Step`'s constructor is private, so every step extends
`ReversibleStep`, `IrreversibleStep` or `ObservingStep` — there is no fourth option and no default.
An irreversible step states what is lost, and because every step declares this, the dry run can name
the point beyond which the run cannot be taken back.

## Plugins

The framework knows nothing about what is being deployed. A plugin brings the steps, the predicates
they are gated on and the programs that order them, and it names itself:

```yaml
# ansiwise.yaml — data, never logic. A list of names, no conditions, no expressions.
plugins:
  - example-plugin
```

Dart compiled ahead of time loads no code at run time, so which plugins EXIST is a fact of the build.
What this file decides is which of them are **active** — and that is a real decision: a step of an
inactive plugin cannot be named in a program file even though its class is in the binary. A name the
binary was not built with is refused together with the names it does carry, so the fix reads as a
different build rather than a different line in a file.

`api-purity` scans this repository to the byte for the name of any platform, with no exempt path. If
a plugin's vocabulary ever appears here, the build goes red.

## The interfaces

Every operation is reachable two ways, and both go through the same gate:

| | |
|---|---|
| the command line | `ansiwise <program> --mode test\|dry\|run` |
| REST | `GET /programs` · `POST /runs` · `GET /runs` · `GET /runs/{id}` · `GET /runs/{id}/events?from=N` |

Nothing listens on a port. `ansiwise serve` speaks HTTP over its own standard input and output, so a
client opens an SSH session, starts it there, and the session's own channel is the transport. SSH
remains the only authentication, and when the session closes no process is left.

A run started with `POST /runs` runs detached and answers with its id, so a laptop may close. Coming
back is `GET /runs/{id}/events?from=N` — every event carries a dense sequence number that is never
reused, so a re-attach has no gap and no duplicate.

## Building it

```
dart run tool/ci.dart     # the gate: the pinned toolchain, the analyzer, and the whole test suite
```

That is the only CI. Nothing hosted runs these checks.

## License

**Noncommercial use is free** — personal study, hobby projects, research, and use by charities,
schools, public research bodies and government institutions.

**Companies need a commercial license from Simetrix GmbH.** Open an issue titled
`Commercial licence`.

See [LICENSE.md](LICENSE.md) for the terms, and for what happens to your copyright when you open a
pull request.
