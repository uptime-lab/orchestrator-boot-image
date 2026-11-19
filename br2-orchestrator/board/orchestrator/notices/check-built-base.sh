#!/bin/sh
#
# Assert that the base id in source-offer.env names what was actually BUILT:
# the Buildroot release recorded in each output tree's .config, the commit of
# this external tree the build consumed, and -- because those two are only
# labels -- the corpus itself: the configurations, package sources, kernels and
# rootfs the committed source-manifest beside source-offer.env records
# (notices/source-manifest.py). assemble-boot-img.sh runs it before it writes
# the offer into the image, so a clean rebuild cannot ship an offer that still
# names the PREVIOUS base (and the previous bundle's sha256), and a build whose
# configuration or rootfs moved while the release and the commit stayed put
# cannot ship that base's offer either.
#
# Usage: check-built-base.sh [--env FILE] [--tree DIR] [--manifest FILE]
#                            [--allow-uncommitted-manifest] OUT_CM4 OUT_CM5
#
#   --env FILE       source-offer.env to read (default: the one beside notices/)
#   --tree DIR       the br2-orchestrator directory whose commit the base names
#                    (default: the one holding this script)
#   --manifest FILE  the source manifest (default: source-manifest beside the env)
#   --allow-uncommitted-manifest
#                    accept an uncommitted source-manifest and source-SHA256SUMS:
#                    the generator's own first run for a new base, before the
#                    two are committed. Without it an uncommitted manifest is
#                    refused, because a manifest nobody committed can have been
#                    re-bound to anything (assemble-boot-img.sh passes it when
#                    ALLOW_UNCOMMITTED_MANIFEST=1 is set)
#   OUT_CM4 OUT_CM5  the two Buildroot output trees (O=) the image is assembled
#                    from, BCM2711 first; `make legal-info` must have run in both
#
# The build commit is the one the env names. HEAD of the tree must be that
# commit, or a descendant of it whose only changes are the base's records
# (source-offer.env, source-manifest, source-SHA256SUMS): committing them after
# the build is the normal flow. The working tree must have no uncommitted
# change except to source-offer.env (`make-source-bundle.sh --write-env`
# writes it for the build at hand) and, with the flag above, the manifest
# files. The build date part of the id is not checked; nothing in an output
# tree records the day a bundle was cut.
#
# Exit 0 when the base matches, 1 when it does not or when the manifest has a
# pending field (pending is not a pass), 2 on usage or when what was built
# cannot be read (no .config, not a git checkout, no legal-info, no python3):
# an unknowable build is refused, not waved through.

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BOARD_DIR=$(CDPATH= cd -- "$HERE/.." && pwd)
ENV_FILE="$BOARD_DIR/source-offer.env"
MANIFEST=""
TREE=$(CDPATH= cd -- "$BOARD_DIR/../.." && pwd)
OUTS=""
ALLOW_MANIFEST=0

die() { echo "check-built-base: $1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_FILE=${2:?--env needs a file}; shift 2 ;;
    --tree) TREE=${2:?--tree needs a directory}; shift 2 ;;
    --manifest) MANIFEST=${2:?--manifest needs a file}; shift 2 ;;
    --allow-uncommitted-manifest) ALLOW_MANIFEST=1; shift ;;
    -h|--help) usage ;;
    -*) echo "check-built-base: unknown option $1" >&2; usage ;;
    *) OUTS="$OUTS $1"; shift ;;
  esac
done
[ -n "$OUTS" ] || usage
[ -f "$ENV_FILE" ] || die "offer facts not found: $ENV_FILE" 2
[ -n "$MANIFEST" ] || MANIFEST="$(dirname -- "$ENV_FILE")/source-manifest"

# shellcheck disable=SC1090
. "$ENV_FILE"
: "${SOURCE_BASE_ID:?SOURCE_BASE_ID missing from $ENV_FILE}"
case "$SOURCE_BASE_ID" in
  buildroot-*+br2-*+[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) die "SOURCE_BASE_ID must look like buildroot-<ver>+br2-<commit>+<YYYYMMDD>, got: $SOURCE_BASE_ID" 2 ;;
esac
ENV_BR_VERSION=${SOURCE_BASE_ID#buildroot-}
ENV_BR_VERSION=${ENV_BR_VERSION%%+*}
ENV_COMMIT=${SOURCE_BASE_ID#*+br2-}
ENV_COMMIT=${ENV_COMMIT%%+*}

# 1. The Buildroot release, from the header Buildroot writes into every
#    output tree's .config ("# Buildroot 2026.02.3 Configuration"). A suffix
#    from setlocalversion (-dirty, -g<hash>) means the build did not run on the
#    release the id names.
built_version=""
for out in $OUTS; do
  cfg="$out/.config"
  [ -f "$cfg" ] || die "$cfg not found; is $out a Buildroot output tree?" 2
  v=$(sed -n 's/^# Buildroot \([^ ]*\) Configuration$/\1/p' "$cfg" | head -1)
  [ -n "$v" ] || die "$cfg carries no '# Buildroot <version> Configuration' header" 2
  if [ -z "$built_version" ]; then
    built_version=$v
  elif [ "$v" != "$built_version" ]; then
    die "the output trees were built by different Buildroot releases ($built_version vs $v in $out)"
  fi
done
if [ "$built_version" != "$ENV_BR_VERSION" ]; then
  die "built with Buildroot $built_version, but source-offer.env names Buildroot $ENV_BR_VERSION ($SOURCE_BASE_ID); run scripts/make-source-bundle.sh --write-env for this build first"
fi

# 2. The commit of this tree. The env's commit is what the build consumed; the
#    bundle archives exactly that commit, so a modification elsewhere in the
#    tree would make the image differ from what the id names.
command -v git >/dev/null 2>&1 || die "git is required to read the built commit" 2
head=$(git -C "$TREE" rev-parse --verify HEAD 2>/dev/null) || die "$TREE is not a git checkout; the built commit cannot be read" 2
# The base's records, matched on git's own repository-relative output, not
# through a pathspec: an absolute path through a symlinked temp or home
# directory is "outside the repository" to git and would silently match nothing.
is_env='[ /]board/orchestrator/source-offer\.env$'
is_manifest='[ /]board/orchestrator/source-(manifest|SHA256SUMS)$'
# Untracked files are ignored, except a manifest that was never committed.
status=$(git -C "$TREE" status --porcelain --untracked-files=all -- .) || die "git status failed in $TREE" 2
dirty=$(printf '%s\n' "$status" | grep -v "$is_env" | grep -Ev '^\?\? ' | grep -v '^$' || true)
untracked=$(printf '%s\n' "$status" | grep -E '^\?\? ' | grep -E "$is_manifest" || true)
[ -z "$untracked" ] || dirty="$dirty
$untracked"
dirty=$(printf '%s\n' "$dirty" | grep -v '^$' || true)
if [ "$ALLOW_MANIFEST" -eq 1 ]; then
  dirty=$(printf '%s\n' "$dirty" | grep -Ev "$is_manifest" | grep -v '^$' || true)
fi
if [ -n "$dirty" ]; then
  case "$dirty" in
    *source-manifest*|*source-SHA256SUMS*) hint="
(an uncommitted source manifest is accepted only on the generator's first run for a new
base, with --allow-uncommitted-manifest; otherwise commit it, or restore the committed one)" ;;
    *) hint="" ;;
  esac
  die "$TREE has uncommitted changes, so no commit names what was built:
$dirty$hint"
fi
env_full=$(git -C "$TREE" rev-parse --verify --quiet "${ENV_COMMIT}^{commit}" 2>/dev/null || true)
if [ "$env_full" != "$head" ]; then
  short=$(git -C "$TREE" rev-parse --short=8 HEAD)
  if [ -n "$env_full" ] && git -C "$TREE" merge-base --is-ancestor "$env_full" "$head" 2>/dev/null; then
    # A descendant is the build commit only when everything it changed is a
    # record of the base itself.
    changed=$(git -C "$TREE" -c core.quotePath=false diff --name-only "$env_full" "$head" -- . |
      grep -Ev 'board/orchestrator/source-(offer\.env|manifest|SHA256SUMS)$' || true)
    if [ -n "$changed" ]; then
      die "HEAD ($short) changed more than the base's records since br2-$ENV_COMMIT, the commit source-offer.env names ($SOURCE_BASE_ID):
$changed
run scripts/make-source-bundle.sh --write-env for this build first"
    fi
  else
    die "built from commit $short of the external tree, but source-offer.env names br2-$ENV_COMMIT ($SOURCE_BASE_ID); run scripts/make-source-bundle.sh --write-env for this build first"
  fi
fi

# 3. The corpus. Steps 1 and 2 compare labels: a build whose .config, kernel
#    or BusyBox configuration, package sources or rootfs changed while the
#    release and the commit stayed put passes both, and its image would offer
#    a bundle that is not its source. The manifest records what the base IS,
#    measured from the build the bundle was cut from; this build must measure
#    the same. The overlay paths (the agent among them) are outside the rootfs
#    digest, so an agent-only rebake keeps the base.
# shellcheck disable=SC2086
set -- $OUTS
[ $# -eq 2 ] || die "the corpus check needs exactly two output trees, out-cm4 then out-cm5 (got $#)" 2
command -v python3 >/dev/null 2>&1 || die "python3 is required for the corpus check (notices/source-manifest.py)" 2
set +e
python3 -I "$HERE/source-manifest.py" check --manifest "$MANIFEST" --env "$ENV_FILE" \
  --tree "$TREE" --out-cm4 "$1" --out-cm5 "$2"
rc=$?
set -e
case "$rc" in
  0) ;;
  3) die "the source manifest has pending fields, and pending is not a pass; the first build
  of a base fills them: notices/source-manifest.py generate --out-cm4 <dir> --out-cm5 <dir>" 1 ;;
  2) die "the corpus of this build cannot be measured (above)" 2 ;;
  *) die "this build is not the corpus the manifest records for $SOURCE_BASE_ID; a clean
  rebuild is a new base: scripts/make-source-bundle.sh --write-env, then notices/source-manifest.py generate" 1 ;;
esac

echo "check-built-base: ok, base $SOURCE_BASE_ID is Buildroot $built_version at external-tree commit $ENV_COMMIT, with the corpus $(basename -- "$MANIFEST") records"
