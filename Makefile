.PHONY: build test check app run
build:
	swift build -j 2
test:
	swift test -j 2
check: build test
app:
	bash Scripts/build_app.sh
run: app
	open build/PhotoAtelier.app
