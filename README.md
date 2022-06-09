# Demo
This is a demo of using [Dagger](https://docs.dagger.io/1235/what) to implement the following CI/CD DAG:
![A DAG of a CI/CD pipeline. There are two root vertices for the client and server source code. There are vertices for building the client app and the server, each with a dependency on their respective source vertex. Similarly, there are two vertices for client and server unit tests, each also with a dependency on their respective source vertex. There is a single vertex for running integration tests, which has dependencies on both of the build vertices for the client and the server. Finally, there are two vertices for releasing the client app and deploying the server. These vertices both have a dependency on the integration test vertex in addition to dependencies on their respective unit test and build vertices.](https://github.com/sipsma/dagger-demo/blob/main/cicd_dag.png?raw=true)

More context can be found in my [PlatformCon 2022 talk](https://www.youtube.com/watch?v=yRhb-Wk5ov4).

To summarize here:

The goal of this DAG is to build, test and release a simple client and server. For the demo, the server is an AWS Lambda function (written in javascript). The client is a simple go binary that just invokes the Lambda function (using a public HTTP endpoint) and prints its response.

The integration test step deploys the Lambda function to a test endpoint, builds the client and then invokes the client against the test endpoint, validating the output is as expected.

The "release client" step will upload the client binary to an S3 bucket (and also export it to a local directory, for demo-ing convenience). The "deploy server" step will, as expected, deploy the Lambda function to the prod endpoint.

Dependencies between these steps are setup to ensure that the client and server are only released/deployed when they have both been verified to pass both unit and integration tests. Each execution also takes advantage of BuildKit's intelligent caching ability to ensure that steps only re-run when their inputs have changed.

## Try it Yourself
There's a few pre-reqs to try this demo out yourself:
1. Clone this repo locally
1. [Install Dagger](https://docs.dagger.io/install)
1. Setup AWS credentials (to deploy AWS Lambda functions and create an S3 bucket)
   * `demo.cue` will read `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables
1. Setup a [Pulumi access token](https://www.pulumi.com/docs/intro/pulumi-service/accounts/#access-tokens)
   * `demo.cue` will read the `PULUMI_ACCESS_TOKEN` environment variable

From there, you should be able to simply run `dagger do all` from this locally pulled repo and watch Dagger build, test and deploy everything for you. Note that this will result in the creation of the following AWS resources:
* An S3 bucket with a name `<your username>-dagger-demo` (can be overriden by setting the `BUCKET_NAME` env var)
* Two Lambda functions with name prefixed with `dagger-demo-`
* Two IAM roles for the Lambda functions, each with name prefixed with `iamForLambda`

Individual parts of the DAG can be run too by running `dagger do <action>`, where `<action>` is a field under the `actions` key in `demo.cue`. You can list the available actions by just running `dagger do`.

### Overview of Code
* The main implementation of the [Dagger plan](https://docs.dagger.io/1202/plan) is in `demo.cue`. See the comments within for more details.
* The client code is a very simple go main func found under `client/`.
* The server code is a NodeJS AWS Lambda handler managed with yarn found under `server/`.
* The `pulumi/` dir contains the pulumi resource specification for creating the Lambda functions
* `cue.mod` is where CUE package dependencies are automatically stored when `dagger project update` is run ([see docs here](https://docs.dagger.io/1215/what-is-cue/#packages)).

## Learn More
* [Dagger Documentation](https://docs.dagger.io/)
* [Todoapp Dagger Example](https://github.com/dagger/todoapp)
