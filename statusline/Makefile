CC ?= clang
CFLAGS ?= -O3 -Wall -Wextra
TARGET = statusline_bin
SRC = statusline.c
WRAPPER = statusline.sh
INSTALL_DIR = $(HOME)/.gemini/antigravity-cli

.PHONY: all build install test clean

# 기본 빌드
all: build

build: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(SRC) -o $(TARGET)
	@echo "Build complete: $(TARGET)"

# agy cli 설정 경로에 자동 설치
install: $(TARGET)
	@mkdir -p $(INSTALL_DIR)
	cp $(TARGET) $(INSTALL_DIR)/$(TARGET)
	cp $(WRAPPER) $(INSTALL_DIR)/$(WRAPPER)
	chmod +x $(INSTALL_DIR)/$(TARGET) $(INSTALL_DIR)/$(WRAPPER)
	@echo "Installed to $(INSTALL_DIR)/"

# 동작 및 렌더링 테스트 (install 후 실행 경로에서 안전하게 테스트)
test: install
	@echo "=== 1. Normal JSON Test ==="
	@echo '{"agent_state":"working","context_window":{"used_percentage":45.8},"model":{"display_name":"Gemini 3.7 Flash"},"cwd":"/data/data/com.termux/files/home/workspace/test","vcs":{"branch":"main","dirty":true},"terminal_width":100}' | $(INSTALL_DIR)/$(WRAPPER)
	@echo "\n=== 2. Empty Input Test ==="
	@$(INSTALL_DIR)/$(WRAPPER) </dev/null
	@echo "\n=== 3. Ready State Test (Wide Layout) ==="
	@echo '{"agent_state":"idle","context_window":{"used_percentage":12.3},"model":{"display_name":"Gemini 3.7 Flash"},"terminal_width":130}' | $(INSTALL_DIR)/$(WRAPPER)

# 정리
clean:
	rm -f $(TARGET)
	@echo "Cleaned up $(TARGET)"
