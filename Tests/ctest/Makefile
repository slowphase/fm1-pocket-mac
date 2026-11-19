# Builds and runs the host test with the system C compiler (Linux or macOS): make -C Tests/ctest
W = ../../Sources/CWasm3
SRC = $(wildcard $(W)/source/m3_*.c) ../../Sources/FM1Host/fm1host.c host_test.c
CFLAGS = -std=gnu11 -O3 -DNASSERTS -UDEBUG -fomit-frame-pointer -fno-stack-protector -I$(W)/include -I$(W)/source -I../../Sources/FM1Host/include
host_test: $(SRC)
	$(CC) $(CFLAGS) -w $(SRC) -o $@ -lm -lpthread
test: host_test
	./host_test ../../Resources/h1.rfm1
.PHONY: test
