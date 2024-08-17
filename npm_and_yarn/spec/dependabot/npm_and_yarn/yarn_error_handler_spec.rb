# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/npm_and_yarn/file_updater/yarn_lockfile_updater"
require "dependabot/npm_and_yarn/dependency_files_filterer"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/shared_helpers"
require "dependabot/errors"

RSpec.describe Dependabot::NpmAndYarn::YarnErrorHandler do
  subject(:error_handler) { described_class.new(dependencies: dependencies, dependency_files: dependency_files) }

  let(:dependencies) { [dependency] }
  let(:error) { instance_double(Dependabot::SharedHelpers::HelperSubprocessFailed, message: error_message) }

  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: version,
      requirements: [],
      previous_requirements: [],
      package_manager: "npm_and_yarn"
    )
  end
  let(:dependency_files) { project_dependency_files("yarn/git_dependency_local_file") }

  let(:credentials) do
    [Dependabot::Credential.new({
      "type" => "git_source",
      "host" => "github.com"
    })]
  end

  let(:dependency_name) { "@segment/analytics.js-integration-facebook-pixel" }
  let(:version) { "github:segmentio/analytics.js-integrations#2.4.1" }
  let(:yarn_lock) do
    dependency_files.find { |f| f.name == "yarn.lock" }
  end

  let(:tmp_path) { Dependabot::Utils::BUMP_TMP_DIR_PATH }

  describe "#initialize" do
    it "initializes with dependencies and dependency files" do
      expect(error_handler.send(:dependencies)).to eq(dependencies)
      expect(error_handler.send(:dependency_files)).to eq(dependency_files)
    end
  end

  describe "#handle_error" do
    context "when the error message contains a yarn error code that is mapped" do
      let(:error_message) { "YN0002: Missing peer dependency" }

      it "raises the corresponding error class with the correct message" do
        expect { error_handler.handle_error(error, { yarn_lock: yarn_lock }) }
          .to raise_error(Dependabot::DependencyFileNotResolvable, /YN0002: Missing peer dependency/)
      end
    end

    context "when the error message contains a recognized pattern" do
      let(:error_message) { "Here is a recognized error pattern: authentication token not provided" }

      it "raises the corresponding error class with the correct message" do
        expect { error_handler.handle_error(error, { yarn_lock: yarn_lock }) }
          .to raise_error(Dependabot::PrivateSourceAuthenticationFailure, /authentication token not provided/)
      end
    end

    context "when the error message contains unrecognized patterns" do
      let(:error_message) { "This is an unrecognized pattern that should not raise an error." }

      it "does not raise an error" do
        expect { error_handler.handle_error(error, { yarn_lock: yarn_lock }) }.not_to raise_error
      end
    end

    context "when the error message contains multiple unrecognized yarn error codes" do
      let(:error_message) do
        "➤ YN0000: ┌ Resolution step\n" \
          "➤ YN0000: ┌ Fetch step\n" \
          "➤ YN0099: │ some-dummy-package@npm:1.0.0 can't be found\n" \
          "➤ YN0099: │ some-dummy-package@npm:1.0.0: The remote server failed\n" \
          "➤ YN0000: └ Completed\n" \
          "➤ YN0000: Failed with errors in 1s 234ms"
      end

      it "does not raise an error" do
        expect { error_handler.handle_error(error, { yarn_lock: yarn_lock }) }.not_to raise_error
      end
    end

    context "when the error message contains multiple yarn error codes with the last one recognized" do
      let(:error_message) do
        "➤ YN0000: ┌ Resolution step\n" \
          "➤ YN0002: │ dummy-package@npm:1.2.3 doesn't provide dummy (p1a2b3)\n" \
          "➤ YN0060: │ dummy-package@workspace:. provides dummy-tool (p4b5c6)\n" \
          "➤ YN0002: │ another-dummy-package@npm:4.5.6 doesn't provide dummy (p7d8e9)\n" \
          "➤ YN0000: └ Completed in 0s 123ms\n" \
          "➤ YN0000: ┌ Fetch step\n" \
          "➤ YN0080: │ some-dummy-package@npm:1.0.0 can't be found\n" \
          "➤ YN0080: │ some-dummy-package@npm:1.0.0: The remote server failed\n" \
          "➤ YN0000: └ Completed\n" \
          "➤ YN0000: Failed with errors in 1s 234ms"
      end

      it "raises a MisconfiguredTooling error with the correct message" do
        expect do
          error_handler.handle_yarn_error(error, { yarn_lock: yarn_lock })
        end.to raise_error(Dependabot::MisconfiguredTooling, /YN0080: .*The remote server failed/)
      end
    end

    context "when the error message contains a node version not satisfy regex and versions are extracted" do
      let(:error_message) do
        "\e[94m➤\e[39m YN0000: · Yarn 4.0.2\n\e[94m➤\e[39m \e[90mYN0000\e[39m: ┌ Project validation\n" \
          "::group::Project validation\n" \
          "\e[91m➤\e[39m YN0000: │ \e[31mThe current \e[32mNode\e[39m\e[31m version \e[36m20.13.1\e[39m\e[31m does" \
          " not satisfy the required version \e[36m20.11.0\e[39m\e[31m.\e[39m\n::endgroup::\n\e[91m➤\e[39m YN0000:" \
          " \e[31mThe current \e[32mNode\e[39m\e[31m version \e[36m20.13.1\e[39m\e[31m does not satisfy the required " \
          "version \e[36m20.11.0\e[39m\e[31m.\e[39m\n" \
          "\e[94m➤\e[39m \e[90mYN0000\e[39m: └ Completed\n\e[91m➤\e[39m YN0000: · Failed with errors in 0s 3ms"
      end

      it "raises a ToolVersionNotSupported error with the correct versions" do
        expect do
          error_handler.handle_error(error, { yarn_lock: yarn_lock })
        end.to raise_error(Dependabot::ToolVersionNotSupported) do |e| # rubocop:disable Style/MultilineBlockChain
          expect(e.tool_name).to eq("Yarn")
          expect(e.detected_version).to eq("20.13.1")
          expect(e.supported_versions).to eq("20.11.0")
        end
      end
    end

    context "when the error message contains SUB_DEP_LOCAL_PATH_TEXT" do
      let(:error_message) { "Some error occurred: refers to a non-existing file" }

      it "raises a DependencyFileNotResolvable error with the correct message" do
        expect { error_handler.handle_error(error, { yarn_lock: yarn_lock }) }
          .to raise_error(
            Dependabot::DependencyFileNotResolvable,
            %r{@segment\/analytics\.js-integration-facebook-pixel}
          )
      end
    end

    context "when the error message matches INVALID_PACKAGE_REGEX" do
      let(:error_message) { "Can't add \"invalid-package\": invalid" }

      it "raises a DependencyFileNotResolvable error with the correct message" do
        expect { error_handler.handle_error(error, { yarn_lock: yarn_lock }) }
          .to raise_error(
            Dependabot::DependencyFileNotResolvable,
            %r{@segment\/analytics\.js-integration-facebook-pixel}
          )
      end
    end

    context "when the error message contains YN0082" do
      let(:error_message) do
        "[94m➤[39m YN0000: · Yarn 4.3.1\n" \
          "[94m➤[39m [90mYN0000[39m: ┌ Resolution step\n::group::Resolution step\n" \
          "[91m➤[39m YN0082: │ [38;5;173mstring-width-cjs[39m[38;5;37m@[39m[38;5;37mnpm:^4.2.3[39m: " \
          "No candidates found\n::endgroup::\n" \
          "[91m➤[39m YN0082: [38;5;173mstring-width-cjs[39m[38;5;37m@[39m[38;5;37mnpm:^4.2.3[39m: " \
          "No candidates found\n" \
          "[94m➤[39m [90mYN0000[39m: └ Completed\n" \
          "[91m➤[39m YN0000: · Failed with errors in 0s 158ms"
      end

      it "raises a DependencyNotFound error with the correct message" do
        expect do
          error_handler.handle_error(error, { yarn_lock: yarn_lock })
        end.to raise_error(Dependabot::DependencyNotFound, /string-width-cjs@npm:\^4.2.3/)
      end
    end
  end

  describe "#find_usage_error" do
    context "when there is a usage error in the message" do
      let(:error_message) { "Some initial text. Usage Error: This is a specific usage error.\nERROR" }

      it "returns the usage error text" do
        usage_error = error_handler.find_usage_error(error_message)
        expect(usage_error).to include("Usage Error: This is a specific usage error.\nERROR")
      end
    end

    context "when there is no usage error in the message" do
      let(:error_message) { "This message does not contain a usage error." }

      it "returns nil" do
        usage_error = error_handler.find_usage_error(error_message)
        expect(usage_error).to be_nil
      end
    end
  end

  describe "#handle_yarn_error" do
    context "when the error message contains yarn error codes" do
      let(:error_message) { "YN0002: Missing peer dependency" }

      it "raises the corresponding error class with the correct message" do
        expect do
          error_handler.handle_yarn_error(error, { yarn_lock: yarn_lock })
        end.to raise_error(Dependabot::DependencyFileNotResolvable, /YN0002: Missing peer dependency/)
      end
    end

    context "when the error message contains multiple yarn error codes" do
      let(:error_message) do
        "YN0001: Exception error\n" \
          "YN0002: Missing peer dependency\n" \
          "YN0016: Remote not found\n"
      end

      it "raises the last corresponding error class found with the correct message" do
        expect do
          error_handler.handle_yarn_error(error, { yarn_lock: yarn_lock })
        end.to raise_error(Dependabot::GitDependenciesNotReachable, /YN0016: Remote not found/)
      end
    end

    context "when the error message does not contain Yarn error codes" do
      let(:error_message) { "This message does not contain any known Yarn error codes." }

      it "does not raise any errors" do
        expect { error_handler.handle_yarn_error(error, { yarn_lock: yarn_lock }) }.not_to raise_error
      end
    end

    context "when the error message contains YN0035" do
      context "when error message matches with YN0035.PACKAGE_NOT_FOUND" do
        let(:error_message) do
          "[94m➤[39m YN0000: · Yarn 4.2.2\n" \
            "[94m➤[39m [90mYN0000[39m: ┌ Resolution step\n::group::Resolution step\n" \
            "[91m➤[39m YN0035: │ [38;5;166m@dummy-scope/[39m[38;5;173mdummy-package" \
            "[39m[38;5;37m@[39m[38;5;37mnpm:^1.2.3[39m: Package not found\n" \
            "[91m➤[39m YN0035: │   [38;5;111mResponse Code[39m: [38;5;220m404[39m (Not Found)\n" \
            "[91m➤[39m YN0035: │   [38;5;111mRequest Method[39m: GET\n" \
            "[91m➤[39m YN0035: │   [38;5;111mRequest URL[39m: [38;5;" \
            "170mhttps://registry.yarnpkg.com/@dummy-scope%2fdummy-package[39m\n::endgroup::\n" \
            "[91m➤[39m YN0035: [38;5;166m@dummy-scope/[39m[38;5;173mdummy-package" \
            "[39m[38;5;37m@[39m[38;5;37mnpm:^1.2.3[39m: Package not found\n" \
            "[91m➤[39m YN0035:   [38;5;111mResponse Code[39m: [38;5;220m404[39m (Not Found)\n" \
            "[91m➤[39m YN0035:   [38;5;111mRequest Method[39m: GET\n" \
            "[91m➤[39m YN0035:   [38;5;111mRequest URL[39m: [38;5;" \
            "170mhttps://registry.yarnpkg.com/@dummy-scope%2fdummy-package[39m\n" \
            "[94m➤[39m [90mYN0000[39m: └ Completed in 0s 291ms\n" \
            "[91m➤[39m YN0000: · Failed with errors in 0s 303ms"
        end

        it "raises error with captured `package_req`" do
          expect do
            error_handler.handle_yarn_error(error, { yarn_lock: yarn_lock })
          end.to raise_error(
            Dependabot::DependencyNotFound,
            %r{The following dependency could not be found : @dummy-scope/dummy-package@npm:\^1.2.3}
          )
        end
      end

      context "when error message matches with YN0035.FAILED_TO_RETRIEVE" do
        let(:error_message) do
          "Dependabot::SharedHelpers::HelperSubprocessFailed: [94m➤[39m[90mYN0000" \
            "[39m: ┌ Project validation\n::group::Project validation\n[93m➤[39m YN0057: │ " \
            "[38;5;166m@dummy-scope/[39m[38;5;173mdummy-connect[39m: Resolutions field" \
            " will be ignored\n[93m➤[39m YN0057: │ [38;5;166m@dummy-scope/[39m[38;5;" \
            "173mdummy-js[39m: Resolutions field will be ignored\n::endgroup::\n[94m➤" \
            "[39m [90mYN0000[39m: └ Completed\n[94m➤[39m [90mYN0000[39m: ┌ Resolution" \
            " step\n::group::Resolution step\n[91m➤[39m YN0035: │ [38;5;166m@dummy-scope/" \
            "[39m[38;5;173mdummy-fixture[39m[38;5;37m@[39m[38;5;37mnpm:^1.0.0[39m: " \
            "The remote server failed to provide the requested resource\n[91m➤[39m YN0035: " \
            "│   [38;5;111mResponse Code[39m: [38;5;220m404[39m (Not Found)\n[91m➤" \
            "[39m YN0035: │   [38;5;111mRequest Method[39m: GET\n[91m➤[39m YN0035: │  " \
            " [38;5;111mRequest URL[39m: [38;5;170m" \
            "https://registry.yarnpkg.com/@dummy-scope%2fdummy-fixture\n::endgroup::\n" \
            "[94m➤[39m [90mYN0000[39m: └ Completed in 0s 566ms\n[91m➤[39m YN0000: Failed with errors in 0s 571ms"
        end

        it "raises error with captured `package_req`" do
          expect do
            error_handler.handle_yarn_error(error, { yarn_lock: yarn_lock })
          end.to raise_error(
            Dependabot::DependencyNotFound,
            %r{The following dependency could not be found : @dummy-scope/dummy-fixture@npm:\^1.0.0}
          )
        end
      end

      context "when error message doesn't match any YN0035.* regex patterns" do
        let(:error_message) do
          "➤ YN0000: · Yarn 4.3.1 " \
            "➤ YN0000: ┌ Resolution step" \
            "➤ YN0035: │ @dummy-scope/dummy-fixture@npm:1.0.0: not found" \
            "➤ YN0000: └ Completed in 0s 662ms" \
            "➤ YN0000: · Failed with errors in 0s 683ms"
        end

        it "raises error with the raw message" do
          expect do
            error_handler.handle_yarn_error(error, { yarn_lock: yarn_lock })
          end.to raise_error(
            Dependabot::DependencyNotFound,
            /The following dependency could not be found : \[YN0035\]/
          )
        end
      end

      context "when out of diskspace error" do
        let(:error_message) do
          "fatal: sha1 file '/home/dependabot/dependabot-updater/repo/.git/index.lock' write error. Out of diskspace"
        end
        let(:usage_error_message) { "\nERROR" }

        it "raises the corresponding error class with the correct message" do
          expect { error_handler.handle_group_patterns(error, usage_error_message, { yarn_lock: yarn_lock }) }
            .to raise_error(Dependabot::OutOfDisk,
                            "fatal: sha1 file '/home/dependabot/dependabot-updater/repo/.git/index.lock' " \
                            "write error. Out of diskspace")
        end
      end
    end

    context "when the error message contains YN0082" do
      let(:error_message) do
        "[94m➤[39m YN0000: · Yarn 4.3.1\n" \
          "[94m➤[39m [90mYN0000[39m: ┌ Resolution step\n::group::Resolution step\n" \
          "[91m➤[39m YN0082: │ [38;5;173mstring-width-cjs[39m[38;5;37m@[39m[38;5;37mnpm:^4.2.3[39m: " \
          "No candidates found\n::endgroup::\n" \
          "[91m➤[39m YN0082: [38;5;173mstring-width-cjs[39m[38;5;37m@[39m[38;5;37mnpm:^4.2.3[39m: " \
          "No candidates found\n" \
          "[94m➤[39m [90mYN0000[39m: └ Completed\n" \
          "[91m➤[39m YN0000: · Failed with errors in 0s 158ms"
      end

      it "raises a DependencyNotFound error with the correct message" do
        expect do
          error_handler.handle_yarn_error(error, { yarn_lock: yarn_lock })
        end.to raise_error(Dependabot::DependencyNotFound, /string-width-cjs@npm:\^4.2.3/)
      end
    end
  end

  describe "#handle_group_patterns" do
    let(:error_message) { "Here is a recognized error pattern: authentication token not provided" }
    let(:usage_error_message) { "Usage Error: This is a specific usage error.\nERROR" }

    context "when the error message contains a recognized pattern in the usage error message" do
      let(:error_message_with_usage_error) { "#{error_message}\n#{usage_error_message}" }

      it "raises the corresponding error class with the correct message" do
        expect { error_handler.handle_group_patterns(error, usage_error_message, { yarn_lock: yarn_lock }) }
          .to raise_error(Dependabot::PrivateSourceAuthenticationFailure, /authentication token not provided/)
      end
    end

    context "when the error message contains ESOCKETTIMEDOUT" do
      let(:error_message) do
        "https://registry.us.gympass.cloud/repository/npm-group/@gympass%2fmep-utils: ESOCKETTIMEDOUT"
      end

      it "raises the corresponding error class with the correct message" do
        expect { error_handler.handle_group_patterns(error, usage_error_message, { yarn_lock: yarn_lock }) }
          .to raise_error(Dependabot::PrivateSourceTimedOut, "The following source timed out: " \
                                                             "registry.us.gympass.cloud/repository/" \
                                                             "npm-group/@gympass%2fmep-utils")
      end
    end

    context "when the error message contains YARNRC_ENV_NOT_FOUND" do
      let(:error_message) do
        "Usage Error: Environment variable not found (GITHUB_TOKEN) in [38;5;170m/home/dependabot/dependabot-" \
        "updater/repo/.yarnrc.yml[39m (in [38;5;170m/home/dependabot/dependabot-updater/repo/.yarnrc.yml[39m)

        Yarn Package Manager - 4.0.2

          $ yarn <command>

        You can also print more details about any of these commands by calling them with
        the `-h,--help` flag right after the command name."
      end

      it "raises the corresponding error class with the correct message" do
        expect { error_handler.handle_group_patterns(error, usage_error_message, { yarn_lock: yarn_lock }) }
          .to raise_error(Dependabot::MissingEnvironmentVariable, "Environment variable \"GITHUB_TOKEN\" not" \
                                                                  " found in \".yarnrc.yml\".")
      end
    end

    context "when the error message contains YARNRC_PARSE_ERROR" do
      let(:error_message) do
        "Usage Error: Parse error when loading /home/dependabot/dependabot-updater/repo/.yarnrc.yml; " \
        "please check it's proper Yaml (in particular, make sure you list the colons after each key name)

        Yarn Package Manager - 3.5.1

          $ yarn <command>

        You can also print more details about any of these commands by calling them with
        the `-h,--help` flag right after the command name."
      end

      it "raises the corresponding error class with the correct message" do
        expect { error_handler.handle_group_patterns(error, usage_error_message, { yarn_lock: yarn_lock }) }
          .to raise_error(Dependabot::DependencyFileNotResolvable, "Error while loading \".yarnrc.yml\".")
      end
    end

    context "when the error message contains EAI_AGAIN" do
      let(:error_message) do
        "Request Error: getaddrinfo EAI_AGAIN yarn-plugins.jvdwaal.nl
        at ClientRequest.<anonymous> (/home/dependabot/dependabot-updater/repo/.yarn/releases/yarn-4.4.0.cjs:147:14258)
        at Object.onceWrapper (node:events:634:26)
        at ClientRequest.emit (node:events:531:35)
        at u.emit (/home/dependabot/dependabot-updater/repo/.yarn/releases/yarn-4.4.0.cjs:142:14855)
        at TLSSocket.socketErrorListener (node:_http_client:500:9)
        at TLSSocket.emit (node:events:519:28)
        at emitErrorNT (node:internal/streams/destroy:169:8)
        at emitErrorCloseNT (node:internal/streams/destroy:128:3)
        at process.processTicksAndRejections (node:internal/process/task_queues:82:21)
        at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:120:26)"
      end

      it "raises the corresponding error class with the correct message" do
        expect { error_handler.handle_group_patterns(error, usage_error_message, { yarn_lock: yarn_lock }) }
          .to raise_error(Dependabot::DependencyFileNotResolvable, "Network error while resolving dependency.")
      end
    end

    context "when the error message contains ENOENT" do
      let(:error_message) do
        "Internal Error: ENOENT: no such file or directory, stat '/home/dependabot/dependabot-updater/repo/.yarn/" \
        "releases/yarn-4.3.1.cjs'
        Error: ENOENT: no such file or directory, stat '/home/dependabot/dependabot-updater/repo/.yarn/releases/" \
        "yarn-4.3.1.cjs'"
      end

      it "raises the corresponding error class with the correct message" do
        expect { error_handler.handle_group_patterns(error, usage_error_message, { yarn_lock: yarn_lock }) }
          .to raise_error(Dependabot::DependencyFileNotResolvable, "Internal error while resolving dependency." \
                                                                   "File not found \"yarn-4.3.1.cjs\"")
      end
    end

    context "when the error message contains socket hang up" do
      let(:error_message) do
        "https://registry.npm.taobao.org/vue-template-compiler: socket hang up"
      end

      it "raises the corresponding error class with the correct message" do
        expect { error_handler.handle_group_patterns(error, usage_error_message, { yarn_lock: yarn_lock }) }
          .to raise_error(Dependabot::PrivateSourceTimedOut, "The following source timed out: " \
                                                             "registry.npm.taobao.org/vue-template-compiler")
      end
    end

    context "when the error message contains a recognized pattern in the error message" do
      it "raises the corresponding error class with the correct message" do
        expect { error_handler.handle_group_patterns(error, "", { yarn_lock: yarn_lock }) }
          .to raise_error(Dependabot::PrivateSourceAuthenticationFailure, /authentication token not provided/)
      end
    end

    context "when the error message does not contain recognized patterns" do
      let(:error_message) { "This is an unrecognized pattern that should not raise an error." }

      it "does not raise any errors" do
        expect { error_handler.handle_group_patterns(error, "", { yarn_lock: yarn_lock }) }.not_to raise_error
      end
    end
  end

  describe "#pattern_in_message" do
    let(:patterns) { ["pattern1", /pattern2/] }

    context "when the message contains one of the patterns" do
      let(:message) { "This message contains pattern1 and pattern2." }

      it "returns true" do
        expect(error_handler.pattern_in_message(patterns, message)).to be(true)
      end
    end

    context "when the message does not contain any of the patterns" do
      let(:message) { "This message does not contain the patterns." }

      it "returns false" do
        expect(error_handler.pattern_in_message(patterns, message)).to be(false)
      end
    end
  end
end
