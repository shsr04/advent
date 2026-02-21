SHELL := /bin/bash

CC := clang
CFLAGS ?= -std=c17 -O3 -Wall -Wextra -Wpedantic

METAC_SOURCES := $(sort $(wildcard day*/day*.metac))
COMPILER_SOURCES := compiler/metac.pl $(sort $(wildcard compiler/lib/MetaC/*.pm))

source_to_c = $(dir $1)build/$(notdir $(basename $1)).c
source_to_bin = $(dir $1)build/$(notdir $(basename $1))
source_to_input = $(firstword $(wildcard $(dir $1)real-input.txt $(dir $1)sample-input.txt))
source_to_out = $(dir $1)build/$(notdir $(basename $1)).out

C_ARTIFACTS := $(foreach s,$(METAC_SOURCES),$(call source_to_c,$(s)))
BIN_ARTIFACTS := $(foreach s,$(METAC_SOURCES),$(call source_to_bin,$(s)))
INPUT_SOURCES := $(foreach s,$(METAC_SOURCES),$(if $(wildcard $(call source_to_input,$(s))),$(s),))
RUN_OUTPUTS := $(foreach s,$(INPUT_SOURCES),$(call source_to_out,$(s)))

DAY_TARGETS := $(basename $(notdir $(METAC_SOURCES)))

.PHONY: all c bins run test compiler-test clean list $(DAY_TARGETS)

all: bins

c: $(C_ARTIFACTS)

bins: $(BIN_ARTIFACTS)

run: $(RUN_OUTPUTS)

compiler-test:
	perl compiler/tests/run.pl

test: compiler-test

list:
	@echo "Meta sources:"
	@printf "  %s\n" $(METAC_SOURCES)
	@echo "C artifacts:"
	@printf "  %s\n" $(C_ARTIFACTS)
	@echo "Binaries:"
	@printf "  %s\n" $(BIN_ARTIFACTS)
	@echo "Run outputs:"
	@printf "  %s\n" $(RUN_OUTPUTS)

clean:
	rm -f $(C_ARTIFACTS) $(BIN_ARTIFACTS) $(RUN_OUTPUTS)
	@if [ -d compiler/tests/build ]; then \
		find compiler/tests/build -mindepth 1 ! -name '.gitignore' -delete; \
	fi

define EMIT_BUILD_RULES
$(call source_to_c,$1): $1 $(COMPILER_SOURCES)
	@mkdir -p $$(@D)
	perl compiler/metac.pl $$< -o $$@

$(call source_to_bin,$1): $(call source_to_c,$1)
	@mkdir -p $$(@D)
	$$(CC) $$(CFLAGS) $$< -o $$@
endef

$(foreach src,$(METAC_SOURCES),$(eval $(call EMIT_BUILD_RULES,$(src))))

define EMIT_RUN_RULES
$(call source_to_out,$1): $(call source_to_bin,$1) $(call source_to_input,$1)
	@mkdir -p $$(@D)
	./$(call source_to_bin,$1) < $(call source_to_input,$1) | tee $$@
endef

$(foreach src,$(INPUT_SOURCES),$(eval $(call EMIT_RUN_RULES,$(src))))

define EMIT_DAY_ALIAS
$(basename $(notdir $1)): $(call source_to_bin,$1)
	@if [ -f "$(dir $1)real-input.txt" ]; then \
		./$(call source_to_bin,$1) < "$(dir $1)real-input.txt"; \
	elif [ -f "$(dir $1)sample-input.txt" ]; then \
		./$(call source_to_bin,$1) < "$(dir $1)sample-input.txt"; \
	else \
		echo "No input file found for $(basename $(notdir $1)): expected $(dir $1)real-input.txt or $(dir $1)sample-input.txt" >&2; \
		exit 2; \
	fi
endef

$(foreach src,$(METAC_SOURCES),$(eval $(call EMIT_DAY_ALIAS,$(src))))
