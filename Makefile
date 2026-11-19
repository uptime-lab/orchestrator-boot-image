# Operator entry points around the Buildroot build. The image itself is built
# with Buildroot as br2-orchestrator/README.md describes; these targets wrap the
# licence-notice and corresponding-source scripts so the commands have one
# documented spelling.
#
#   make test                       run the shell tests (no Buildroot, no mtools)
#   make fetch-agent VERSION=x.y.z  put that released agent into the rootfs overlay,
#                                   after verifying its signature (network)
#   make notices-dry-run            show what the notices step would write
#   make check-notices IMG=boot.img assert an image carries the notices, names the
#                                   base in source-offer.env and IS that base's corpus
#   make inject-notices IMG=x.img   add the notices to an existing image (then re-sign)
#   make source-bundle              build the corresponding-source bundle from a
#                                   finished Buildroot build (see variables below)
#   make source-manifest [IMG=..] [BUNDLE=tar] [TOOLCHAIN=file]
#                                   record the corpus of a finished build (and of
#                                   the image assembled from it, and the archives
#                                   the offer names) in source-manifest; the image
#                                   is measured only when IMG= is given on the
#                                   command line
#   make check-source-manifest      compare the build outputs with source-manifest

BUILDROOT ?= ../buildroot
OUT_CM4   ?= $(BUILDROOT)/out-cm4
OUT_CM5   ?= $(BUILDROOT)/out-cm5
DEST      ?= ./dist
IMG       ?= boot.img
BUNDLE_FLAGS ?=
SOURCE_MANIFEST = br2-orchestrator/board/orchestrator/notices/source-manifest.py

TESTS = br2-orchestrator/board/orchestrator/tests/s99agent-master-card.sh \
        br2-orchestrator/board/orchestrator/tests/notices.sh \
        br2-orchestrator/board/orchestrator/tests/built-base.sh \
        br2-orchestrator/board/orchestrator/tests/source-manifest.sh \
        br2-orchestrator/board/orchestrator/tests/fetch-agent.sh \
        br2-orchestrator/board/orchestrator/tests/source-bundle.sh

.PHONY: help test fetch-agent notices-dry-run check-notices inject-notices source-bundle \
        source-manifest check-source-manifest

help:
	@sed -n '1,21p' Makefile | sed 's/^# \{0,1\}//'

test:
	@for t in $(TESTS); do echo "== $$t"; sh "$$t" || exit 1; done

# FETCH_FLAGS=--write-notices also refreshes the committed copy of the agent's
# third-party notices from the package.
fetch-agent:
	@[ -n "$(VERSION)" ] || { echo "usage: make fetch-agent VERSION=<agent version>" >&2; exit 2; }
	@scripts/fetch-agent.sh $(FETCH_FLAGS) $(VERSION)

notices-dry-run:
	@scripts/inject-notices.sh --dry-run $(IMG)

check-notices:
	@scripts/check-notices.sh $(IMG)

inject-notices:
	@scripts/inject-notices.sh $(IMG)

source-bundle:
	@scripts/make-source-bundle.sh --buildroot $(BUILDROOT) --out-cm4 $(OUT_CM4) \
		--out-cm5 $(OUT_CM5) --dest $(DEST) $(BUNDLE_FLAGS)

# The first run, before the assemble step, measures no image, so the FAT-root
# digest stays pending; run it again with IMG= on the command line once
# assemble-boot-img.sh has written the image. IMG's default (and a boot.img
# left over from an earlier build) is never measured by accident.
source-manifest:
	@python3 -I $(SOURCE_MANIFEST) generate --out-cm4 $(OUT_CM4) --out-cm5 $(OUT_CM5) \
		$(if $(filter command line,$(origin IMG)),--image $(IMG)) $(if $(BUNDLE),--bundle $(BUNDLE)) \
		$(if $(TOOLCHAIN),--toolchain $(TOOLCHAIN))

check-source-manifest:
	@python3 -I $(SOURCE_MANIFEST) check --out-cm4 $(OUT_CM4) --out-cm5 $(OUT_CM5)
