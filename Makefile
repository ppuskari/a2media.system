CA65 ?= ca65
LD65 ?= ld65
PYTHON ?= python3

.PHONY: all check clean
all: dist/A2MEDIA.SYSTEM

build/a2media.o: src/a2media.s
	mkdir -p build dist
	$(CA65) -g -l build/A2MEDIA.lst src/a2media.s -o $@

dist/A2MEDIA.SYSTEM: build/a2media.o src/prodos8-system.cfg
	$(LD65) -C src/prodos8-system.cfg -m build/A2MEDIA.map build/a2media.o -o $@
	$(PYTHON) tools/check_sys.py $@

check: all
	$(PYTHON) tools/check_sys.py dist/A2MEDIA.SYSTEM

clean:
	rm -rf build dist
