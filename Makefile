CONF=./dist/setup-config
CABAL=distributed-process-platform.cabal
BUILD_DEPENDS=$(CONF) $(CABAL)

BASE_GIT := git://github.com/haskell-distributed
REPOS=$(shell cat REPOS | sed '/^$$/d')

ifeq ($(dev), 1)
  DEPS_GIT_CLONE_MSG = "\e[31mCloning libraries from development branch\e[0m"
  DEPS_GIT_CLONE_FLAGS = -b development
else
  DEPS_GIT_CLONE_MSG = "\e[32mCloning libraries from master branch\e[0m"
  DEPS_GIT_CLONE_FLAGS =
endif

.PHONY: all
all: build

.PHONY: deps
$(REPOS):
	-git clone $(DEPS_GIT_CLONE_FLAGS) $(BASE_GIT)/$@.git vendor/$@
	cabal sandbox add-source ./vendor/$@
.deps :
	-mkdir vendor
	cabal sandbox init
	@echo -e $(DEPS_GIT_CLONE_MSG)
	make $(REPOS)
	cabal install --only-dependencies --enable-tests
	touch .deps
deps : .deps

.PHONY: test
test: build
	cabal test --show-details=always

.PHONY: build
build: deps configure
	cabal build

.PHONY: configure
configure: $(BUILD_DEPENDS)

.PHONY: ci
ci: test

$(BUILD_DEPENDS):
	cabal configure --enable-tests

.PHONY: clean
clean:
	cabal clean

.PHONY: deepclean
deepclean: clean
	-rm -rf vendor
	-rm -f .deps
	-cabal sandbox delete
