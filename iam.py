import json
import logging
import time
import boto3
from botocore.exceptions import ClientError
from typing import Dict, Any, Optional

logger = logging.getLogger("storybook.iam")

class IAMManager:
    """Manages IAM roles for Bedrock flow execution."""
    
    def __init__(self, config):
        """Initialize IAM manager with configuration."""
        self.config = config
    
    def ensure_role_exists(self) -> Optional[str]:
        """Ensure the IAM role exists, creating it if necessary. Returns the role ARN."""
        role_name = self.config.role_name
        region = self.config.aws_region
        profile = self.config.aws_profile
        table_prefix = self.config.table_prefix
        
        session = boto3.Session(region_name=region, profile_name=profile)
        iam = session.client('iam')
        
        # Check if role already exists
        try:
            response = iam.get_role(RoleName=role_name)
            logger.info(f"IAM role {role_name} already exists")
            return response['Role']['Arn']
        except ClientError as e:
            if e.response['Error']['Code'] != 'NoSuchEntity':
                logger.error(f"Error checking IAM role: {str(e)}")
                return None
            
            # Role doesn't exist, create it
            logger.info(f"Creating IAM role {role_name} for storybook")
            
            # Create the trust policy
            trust_policy = {
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "bedrock.amazonaws.com"},
                    "Action": "sts:AssumeRole"
                }]
            }
            
            # Create Bedrock policy
            bedrock_policy = {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Sid": "BedrockFlowPermissions",
                        "Effect": "Allow",
                        "Action": [
                            "bedrock:CreateFlow",
                            "bedrock:UpdateFlow",
                            "bedrock:GetFlow",
                            "bedrock:ListFlows",
                            "bedrock:DeleteFlow",
                            "bedrock:ValidateFlowDefinition",
                            "bedrock:CreateFlowVersion",
                            "bedrock:GetFlowVersion",
                            "bedrock:ListFlowVersions",
                            "bedrock:DeleteFlowVersion",
                            "bedrock:CreateFlowAlias",
                            "bedrock:UpdateFlowAlias",
                            "bedrock:GetFlowAlias",
                            "bedrock:ListFlowAliases",
                            "bedrock:DeleteFlowAlias",
                            "bedrock:InvokeFlow",
                            "bedrock:TagResource",
                            "bedrock:UntagResource",
                            "bedrock:ListTagsForResource",
                            "bedrock:ApplyGuardrail",
                            "bedrock:InvokeGuardrail",
                            "bedrock:InvokeModel",
                            "bedrock:GetCustomModel",
                            "bedrock:InvokeAgent",
                            "bedrock:Retrieve",
                            "bedrock:RetrieveAndGenerate",
                            "bedrock:GetPrompt",
                            "bedrock:ListPrompts",
                            "bedrock:RenderPrompt",
                            "bedrock:GetAgent",
                            "bedrock:GetKnowledgeBase",
                            "bedrock:GetGuardrail"
                        ],
                        "Resource": "*"
                    }
                ]
            }
            
            # Create DynamoDB policy
            dynamodb_policy = {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Sid": "DynamoDBPermissions",
                        "Effect": "Allow",
                        "Action": [
                            "dynamodb:GetItem",
                            "dynamodb:PutItem",
                            "dynamodb:UpdateItem",
                            "dynamodb:DeleteItem",
                            "dynamodb:Query",
                            "dynamodb:Scan",
                            "dynamodb:BatchGetItem",
                            "dynamodb:BatchWriteItem"
                        ],
                        "Resource": [
                            f"arn:aws:dynamodb:*:*:table/{table_prefix}*"
                        ]
                    }
                ]
            }
            
            try:
                # Create the role
                response = iam.create_role(
                    RoleName=role_name,
                    AssumeRolePolicyDocument=json.dumps(trust_policy)
                )
                
                # Attach policies
                iam.put_role_policy(
                    RoleName=role_name,
                    PolicyName=f"{role_name}BedrockPolicy",
                    PolicyDocument=json.dumps(bedrock_policy)
                )
                
                iam.put_role_policy(
                    RoleName=role_name,
                    PolicyName=f"{role_name}DynamoDBPolicy",
                    PolicyDocument=json.dumps(dynamodb_policy)
                )
                
                logger.info(f"IAM role {role_name} created successfully")
                
                # Sleep to allow IAM role to propagate
                logger.info("Waiting for IAM role to propagate...")
                time.sleep(10)
                
                return response['Role']['Arn']
                
            except ClientError as e:
                logger.error(f"Error creating IAM role: {str(e)}")
                return None

    def create_role(self, role_name: str, trust_policy: Dict[str, Any]) -> Optional[str]:
        """Create an IAM role with the specified trust policy. Returns the role ARN."""
        region = self.config.aws_region
        profile = self.config.aws_profile

        session = boto3.Session(region_name=region, profile_name=profile)
        iam = session.client('iam')

        try:
            response = iam.create_role(
                RoleName=role_name,
                AssumeRolePolicyDocument=json.dumps(trust_policy)
            )
            return response['Role']['Arn']
        except ClientError as e:
            logger.error(f"Error creating IAM role: {str(e)}")
            return None

    def attach_policy(self, role_name: str, policy_name: str, policy_document: Dict[str, Any]) -> bool:
        """Attach a policy to an IAM role. Returns True if successful."""
        region = self.config.aws_region
        profile = self.config.aws_profile

        session = boto3.Session(region_name=region, profile_name=profile)
        iam = session.client('iam')

        try:
            iam.put_role_policy(
                RoleName=role_name,
                PolicyName=policy_name,
                PolicyDocument=json.dumps(policy_document)
            )
            return True
        except ClientError as e:
            logger.error(f"Error attaching policy to IAM role: {str(e)}")
            return False

    def detach_policy(self, role_name: str, policy_name: str) -> bool:
        """Detach a policy from an IAM role. Returns True if successful."""
        region = self.config.aws_region
        profile = self.config.aws_profile

        session = boto3.Session(region_name=region, profile_name=profile)
        iam = session.client('iam')

        try:
            iam.delete_role_policy(
                RoleName=role_name,
                PolicyName=policy_name
            )
            return True
        except ClientError as e:
            logger.error(f"Error detaching policy from IAM role: {str(e)}")
            return False
