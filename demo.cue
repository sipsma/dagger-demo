package main

import (
	"strings"

	"dagger.io/dagger"
	"dagger.io/dagger/core"

	"universe.dagger.io/alpine"
	"universe.dagger.io/aws"
	"universe.dagger.io/go"
	"universe.dagger.io/yarn"

	"universe.dagger.io/x/david@rawkode.dev/pulumi"
)

dagger.#Plan & {
	client: {
		// Write the client binary to the ./bin/ dir on the client's fs
		filesystem: "./bin/": write: contents: actions.buildClient.output
		env: {
			// Read in access keys from the client's env vars as secrets (which
			// stops them from being logged or stored in BuildKit). An alternative
			// implementation could support reading these from the client's 
			// ~/.aws/credentials file.
			AWS_ACCESS_KEY_ID:     dagger.#Secret
			AWS_SECRET_ACCESS_KEY: dagger.#Secret
			PULUMI_ACCESS_TOKEN:   dagger.#Secret
			// Optionally read the BUCKET_NAME env to support overriding the client
			// binary S3 bucket.
			BUCKET_NAME?: string
		}
		// Run the "whoami" command locally on the client to get the client's 
		// username, which is used to generate the default S3 bucket name.
		commands: whoami: name: "whoami"
	}

	actions: {
		// #Source just reads the contents of the directory containing this 
		// `demo.cue` file
		_source: core.#Source & {
			path: "."
		}

		// Build the client binary
		buildClient: go.#Build & {
			source:  _source.output
			package: "./client/"
			tags:    "netgo" // this enables a fully static binary
			os:      client.platform.os
			arch:    client.platform.arch
		}
		// Run unit tests for the client
		unitTestClient: go.#Test & {
			source:  _source.output
			package: "./client/"
			command: flags: "-race": true
		}

		// Server build+test
		_serverDir: core.#Subdir & {
			input: _source.output
			path:  "./server"
		}
		// Package the server into an AWS Lambda deployment zip
		buildServer: #Zip & {
			zipInput: _serverDir.output
			subpath:  "src"
			zipName:  "lambda.zip"
		}
		// Run the server unit tests
		unitTestServer: yarn.#Script & {
			source: _serverDir.output
			name:   "test"
		}

		_deployTestServer: {
			_up: pulumi.#Up & {
				pulumiOpts
				source: _pulumiLambdaDir.output
				container: mounts: lambdazip: core.#Mount & {
					dest:     "/lambda"
					contents: buildServer.output
					ro:       true
				}
				stack: "dev"
			}
			url: _up.outputs.url
		}
		// Run the client+server integ tests
		integTest: #IntegTest & {
			expectedOutput: "Hello from Lambda!"
			clientBin:      buildClient.output
			serverUrl:      _deployTestServer.url
		}

		// If set, use the BUCKET_NAME env var from the client to set the bucket,
		// otherwise fallback to <username>-dagger-demo
		_bucketName: [
				if client.env.BUCKET_NAME != _|_ {
				client.env.BUCKET_NAME
			},
			"\(strings.TrimSpace(client.commands.whoami.stdout))-dagger-demo",
		][0]
		// Upload the client binary to S3.
		// This is meant to be an example of "releasing" it even though this 
		// bucket is private. This step uses the aws package to create a bucket
		// if it doesn't exist yet and then uploads the client binary to it.
		// The aws package is a bit low level relative to options like Pulumi
		// (as seen below) as it's just a wrapper around the aws cli.
		releaseClient: aws.#Container & {
			credentials: aws.#Credentials & {
				accessKeyId:     client.env.AWS_ACCESS_KEY_ID
				secretAccessKey: client.env.AWS_SECRET_ACCESS_KEY
			}
			mounts: {
				// Provide the client binary to the aws cli invocation under /src
				src: core.#Mount & {
					dest:     "/src"
					contents: buildClient.output
					ro:       true
				}
				// Pseudo-dependency that forces the unit tests to run and pass before
				// releasing the client.
				test: core.#Mount & {
					dest:     "/test"
					contents: unitTestClient.output.rootfs
					ro:       true
				}
				// Pseudo-dependency that forces the integ tests to run and pass before
				// releasing the client.
				integtest: core.#Mount & {
					dest:     "/integtest"
					contents: integTest.output
					ro:       true
				}
			}
			command: {
				name: "sh"
				args: ["-c", """
					if [[ ! -z "$(aws s3api head-bucket --bucket \(_bucketName) 2>&1)" ]]; then
					  aws s3api create-bucket --bucket \(_bucketName) --acl private
					fi
					aws s3 cp /src/client s3://\(_bucketName)/client
					"""]
			}
		}

		// Deploy the server code to AWS Lambda using Pulumi
		deployProdServer: {
			_up: pulumi.#Up & {
				pulumiOpts
				source: _pulumiLambdaDir.output
				stack:  "prod"
				container: mounts: {
					// Provide the packaged server to Pulumi for deployment to Lambda
					lambdazip: core.#Mount & {
						dest:     "/lambda"
						contents: buildServer.output
						ro:       true
					}
					// Pseudo-dependency that forces the unit tests to run and pass before
					// deploying the server.
					test: core.#Mount & {
						type:     "fs"
						dest:     "/test"
						contents: unitTestServer.output
						ro:       true
					}
					// Pseudo-dependency that forces the integ tests to run and pass before
					// deploying the server.
					integtest: core.#Mount & {
						type:     "fs"
						dest:     "/integtest"
						contents: integTest.output
						ro:       true
					}
				}
			}
			url: _up.outputs.url
		}

		// Release the client and deploy the server
		all: {
			// targets
			_client: releaseClient
			_server: deployProdServer

			// outputs
			url: _server.url
		}

		// common opts
		_pulumiLambdaDir: core.#Subdir & {
			input: _source.output
			path:  "./pulumi/lambda"
		}
		pulumiOpts: {
			_modCachePath:          "/root/.cache/go-mod"
			_buildCachePath:        "/root/.cache/go-build"
			_pulumiPluginCachePath: "/root/.pulumi/plugins"

			stackCreate: true
			runtime:     "go"
			accessToken: client.env.PULUMI_ACCESS_TOKEN
			container: {
				env: {
					AWS_ACCESS_KEY_ID:     client.env.AWS_ACCESS_KEY_ID
					AWS_SECRET_ACCESS_KEY: client.env.AWS_SECRET_ACCESS_KEY
					AWS_REGION:            "us-west-2"
					GOMODCACHE:            _modCachePath
				}
				mounts: {
					// These setup a few cache mounts at directories Go and Pulumi
					// download dependencies and plugins to. Any contents placed in
					// these directories during execution will be persisted to subsequent
					// executions.
					"go mod cache": {
						contents: core.#CacheDir & {
							id: "pulumi_mod"
						}
						dest: _modCachePath
					}
					"go build cache": {
						contents: core.#CacheDir & {
							id: "pulumi_build"
						}
						dest: _buildCachePath
					}
					"pulumi plugin cache": {
						contents: core.#CacheDir & {
							id: "pulumi_plugin"
						}
						dest: _pulumiPluginCachePath
					}
				}
			}
		}
	}
}

// A simple client+server integ test that asserts the client prints the
// expected output when invoking the server.
#IntegTest: {
	clientBin:      dagger.#FS
	serverUrl:      string
	expectedOutput: string

	_image: alpine.#Build

	_run: core.#Exec & {
		input: _image.output.rootfs
		env: {
			TEST_LAMBDA_URL: serverUrl
			EXPECTED_OUTPUT: expectedOutput
		}
		args: ["sh", "-e", "-c", """
			OUTPUT="$(/clientBin/client $TEST_LAMBDA_URL)"
			if [ "$OUTPUT" != "$EXPECTED_OUTPUT" ]; then
			  echo Expected \\"$EXPECTED_OUTPUT\\" but got \\"$OUTPUT\\"
			  exit 1
			fi
			"""]
		mounts: client: core.#Mount & {
			dest:     "/clientBin"
			contents: clientBin
			ro:       true
		}
	}
	output: _run.output
}

// A small utilty for wrapping an input filesystem into a zip file.
#Zip: {
	zipInput: dagger.#FS
	subpath?: string
	zipName:  string
	output:   dagger.#FS

	_image: alpine.#Build & {
		packages: zip: _
	}

	_run: core.#Exec & {
		input: _image.output.rootfs
		mounts: input: core.#Mount & {
			dest:     "/mnt"
			contents: zipInput
			source:   subpath
			ro:       true
		}
		workdir: "/mnt"
		args: ["zip", "-r", "/\(zipName)", "."]
	}
	_runDiff: core.#Diff & {
		lower: _image.output.rootfs
		upper: _run.output
	}
	output: _runDiff.output
}
