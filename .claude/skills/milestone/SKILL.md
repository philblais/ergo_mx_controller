---
name: milestone
description: Close out a unit of work in the MX Ergo project and write its changelog entry in house style. Use when finishing a feature, adding a package target, or when the user asks to update the changelog, document what was built, or wrap up a milestone.
---

# Milestone

This project advances in reviewed milestones with a consistent shape. Follow it
so the audit trail stays uniform and skimmable.

## The cadence

1. **Build it dormant.** New capability that could reach hardware goes in a
   SwiftPM target with no library product and no app/helper dependency edge.
2. **Add its isolation test.** Mirror an existing one, e.g.
   `compositionTargetIsProductlessUnwiredAndCapabilityMinimal` in
   `PrecisionRuntimeCompositionTests.swift`. It should assert: absent from the
   products half of `Package.swift`, an exact manifest occurrence count, absent
   from `project.yml` and `project.pbxproj`, and a forbidden-token scan over the
   target's sources.
3. **Add adversarial tests**, not just happy paths. The house style tests forged
   authorization, duplicate invocation, cancellation on both sides of a
   boundary, timeout, disconnect, and concurrent shutdown.
4. **Run `scripts/verify.sh`.** Note the new test count.
5. **Write the changelog entry.**

## Changelog entry style

Append to `CHANGELOG.md`. Study the neighbours before writing; the register is
precise, declarative, and unexcited. The reliable shape:

> The *<name>* milestone adds `<Target>` as *<what it owns>*. It has no product,
> IOKit import, app/helper dependency, or executable edge.
>
> *<Two or three paragraphs of what it actually enforces — the specific
> guarantees, in the order the code checks them.>*
>
> *<N>* *<area>* tests raise the package total to *<count>*, all passing. They
> cover *<comma-separated list of the adversarial cases>*. A fresh signed
> menu-app build verifies on disk and satisfies its designated requirement; its
> debug dylib contains no *<forbidden>* symbol. No live HID operation was run.

Rules the existing entries follow without exception:

- **State what was deliberately *not* added.** Half the value of each entry is
  the negative space: no product, no retry, no inverse SET, no CGEvent.
- **Always end with the live-HID status.** "No live HID operation was run" or
  "No live HID write was run in automated tests." Never omit it.
- **Give the exact test count**, not "all tests pass".
- **Name the next gate.** Most entries close by saying what remains prohibited
  and what review would be needed to lift it.
- **Never claim hardware evidence** that came from a test. Hardware claims go in
  `Evidence/VALIDATION-RECORDS.md` and only after a real session.

## Also update

- `README.md` "Where things stand" — only if the milestone changed which of the
  three buckets something sits in.
- `SAFETY.md` — only if a new invariant was established, not for every feature.
- `.claude/skills/safety-gate/SKILL.md` "Current authorization state" — whenever
  a CID's authorization or the CGEvent situation changes. This is the section
  most likely to go stale.

## Commit

One commit per milestone, subject in the imperative. The body should say what
was added, what was deliberately withheld, and the new test count — the same
three things the changelog entry says, more briefly.
