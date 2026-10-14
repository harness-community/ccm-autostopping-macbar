BINARY := CCMAutoStoppingBar

.PHONY: build run package

build:
	swift build

run: build
	swift run

package:
ifndef VERSION
	$(error VERSION is required, e.g. make package VERSION=0.0.3)
endif
	./Scripts/make-app.sh $(VERSION)
