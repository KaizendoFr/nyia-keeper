#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
#
# bin/common/version-policy.sh — immutable release-version POLICY (Plan 346).
#
# Deliberately tiny and side-effect free: it is sourced by BOTH the launcher
# (bin/common/shared.sh) and the updater (lib/auto-update.sh). The updater must never have to
# source the broad launcher library to learn a policy constant — that would couple it to the
# launcher's path assumptions and initialisation side effects across the source, dist-runtime and
# installed layouts (plan review R-High-2, D-3469).
#
# Sourcing this file must do NOTHING except define the constant and the helpers below.

[[ -n "${_NYIA_VERSION_POLICY_LOADED:-}" ]] && return 0
_NYIA_VERSION_POLICY_LOADED=1

# The FIRST release whose images carry per-version :v<version> tags (Plan 344). Anything older never
# had pinned tags at all, so a missing pinned tag there means "predates pinning", NOT "pruned".
# Overridable for tests only; production code must not depend on the override.
NYIA_PINNING_EPOCH="${NYIA_PINNING_EPOCH:-v0.1.0-beta.9}"

# Prerelease family rank. Stable (no prerelease) outranks every prerelease of the same base version.
# An UNKNOWN family returns 0, which callers treat as "cannot order" — the fail-closed direction.
_nyia_family_rank() {
    case "$1" in
        alpha) echo 1 ;;
        beta)  echo 2 ;;
        "")    echo 3 ;;   # stable
        *)     echo 0 ;;   # unknown family (rc, dev, …): not orderable by this policy
    esac
}

# nyia_version_at_or_after_epoch <version>
#   0 = the version is at or after NYIA_PINNING_EPOCH (so it SHOULD carry pinned image tags)
#   1 = it is older, unparseable, or an unknown prerelease family (treat as pre-pinning)
#
# A shape regex alone is not enough: it accepts prerelease families the release pipeline refuses
# (rc.N, dev.N), and mapping those onto the epoch would be a guess (plan review R-Med-1).
nyia_version_at_or_after_epoch() {
    local v="${1:-}" e="${NYIA_PINNING_EPOCH}"
    local re='^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$'

    # "dev", "latest", empty and malformed values are never at-or-after the epoch.
    [[ -n "$v" && "$v" != "dev" && "$v" != "latest" ]] || return 1
    [[ "$v" =~ $re ]] || return 1
    [[ "$e" =~ $re ]] || return 1

    v="${v#v}"; e="${e#v}"
    local vb="${v%%-*}" eb="${e%%-*}"
    local vp="" ep=""
    [[ "$v" == *-* ]] && vp="${v#*-}"
    [[ "$e" == *-* ]] && ep="${e#*-}"

    # Compare X.Y.Z numerically, field by field.
    local i vf ef
    for i in 1 2 3; do
        vf=$(echo "$vb" | cut -d. -f"$i"); ef=$(echo "$eb" | cut -d. -f"$i")
        # 10# forces base-10: an unprefixed 08/09 is an invalid octal literal, which makes (( ))
        # emit a bash error onto the user's terminal AND mis-order the comparison.
        [[ "$vf" =~ ^[0-9]+$ && "$ef" =~ ^[0-9]+$ ]] || return 1
        (( 10#$vf > 10#$ef )) && return 0
        (( 10#$vf < 10#$ef )) && return 1
    done

    # Same base version: order by prerelease family, then by its number.
    local vfam="${vp%%.*}" efam="${ep%%.*}"
    [[ "$vp" == "$vfam" ]] && vfam="$vp"
    local vr er
    vr=$(_nyia_family_rank "$vfam"); er=$(_nyia_family_rank "$efam")
    [[ "$vr" -eq 0 ]] && return 1          # unknown family: not orderable -> pre-pinning
    (( vr > er )) && return 0
    (( vr < er )) && return 1

    # Same family: compare the prerelease number.
    local vn="${vp##*.}" en="${ep##*.}"
    [[ "$vn" =~ ^[0-9]+$ ]] || return 1
    [[ "$en" =~ ^[0-9]+$ ]] || return 1
    (( 10#$vn >= 10#$en )) && return 0
    return 1
}
