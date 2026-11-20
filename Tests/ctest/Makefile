# Builds and runs the host test with the system C compiler (Linux or macOS): make -C Tests/ctest
W = ../../Sources/CWasm3
ENGINE = $(wildcard $(W)/source/m3_*.c) ../../Sources/FM1Host/fm1host.c
SRC = $(ENGINE) host_test.c
CFLAGS = -std=gnu11 -O3 -DNASSERTS -UDEBUG -fomit-frame-pointer -fno-stack-protector -I$(W)/include -I$(W)/source -I../../Sources/FM1Host/include
host_test: $(SRC)
	$(CC) $(CFLAGS) -w $(SRC) -o $@ -lm -lpthread
# FM-1 Pocket Player's boot test in this engine; FM-1 Pocket Player's nightly job builds and runs it
native_smoke: $(ENGINE) native_smoke.c
	$(CC) $(CFLAGS) -w $(ENGINE) native_smoke.c -o $@ -lm -lpthread
test: host_test
	./host_test ../../Resources/h1.rfm1
.PHONY: test
clean:
	rm -f host_test native_smoke
