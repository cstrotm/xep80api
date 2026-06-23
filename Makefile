ASM = atasm

all: xep80hello.com xep80api.com

xep80hello.com: xep80hello.asm xep80api.asm
	$(ASM) -o$@ xep80hello.asm

xep80api.com: xep80api.asm
	$(ASM) -o$@ xep80api.asm

clean:
	rm -f xep80hello.com xep80api.com

.PHONY: all clean
