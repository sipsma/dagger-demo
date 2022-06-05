package main

import (
	"fmt"

	"github.com/pulumi/pulumi-aws/sdk/v5/go/aws/iam"
	"github.com/pulumi/pulumi-aws/sdk/v5/go/aws/lambda"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		iamForLambda, err := iam.NewRole(ctx, "iamForLambda", &iam.RoleArgs{
			AssumeRolePolicy: pulumi.Any(fmt.Sprintf("%v%v%v%v%v%v%v%v%v%v%v%v%v", "{\n", "  \"Version\": \"2012-10-17\",\n", "  \"Statement\": [\n", "    {\n", "      \"Action\": \"sts:AssumeRole\",\n", "      \"Principal\": {\n", "        \"Service\": \"lambda.amazonaws.com\"\n", "      },\n", "      \"Effect\": \"Allow\",\n", "      \"Sid\": \"\"\n", "    }\n", "  ]\n", "}\n")),
		})
		if err != nil {
			return err
		}

		const lambdaName = "dagger-demo"
		lambdaFunc, err := lambda.NewFunction(ctx, lambdaName, &lambda.FunctionArgs{
			Code:    pulumi.NewFileArchive("/lambda/lambda.zip"),
			Role:    iamForLambda.Arn,
			Handler: pulumi.String("index.handler"),
			Runtime: pulumi.String("nodejs14.x"),
			Environment: &lambda.FunctionEnvironmentArgs{
				Variables: pulumi.StringMap{
					"foo": pulumi.String("bar"),
				},
			},
		})
		if err != nil {
			return err
		}

		lambdaUrl, err := lambda.NewFunctionUrl(ctx, "test-dagger-demo", &lambda.FunctionUrlArgs{
			FunctionName:      lambdaFunc.Arn,
			AuthorizationType: pulumi.String("NONE"),
		})
		if err != nil {
			return err
		}

		ctx.Export("url", lambdaUrl.FunctionUrl)

		return nil
	})
}
