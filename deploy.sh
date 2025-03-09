#!/bin/bash

# AWS Bedrock Flow Hierarchical Multi-Agent Deployment Script
# This script helps deploy, modify, or delete a complex Bedrock Flow for Storybook processing
# Requirements: AWS CLI v2.24 or higher, jq, proper AWS permissions

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Global variables
REGION="us-east-1" # Default region - modify if needed
STACK_NAME="storybook"
MODEL_ID="anthropic.claude-3-sonnet-20240229-v1:0" # Default model
FLOW_BUCKET_NAME="storybook-flow"
ROLE_NAME="storybook-flow"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Debug function to print AWS CLI commands before execution
debug_aws_command() {
    echo -e "${YELLOW}AWS CLI Command: $@${NC}"
}

# Agent IDs - will be populated during creation
declare -A AGENT_IDS

# Check dependencies
check_dependencies() {
    echo -e "${BLUE}Checking dependencies...${NC}"

    if ! command -v aws &> /dev/null; then
        echo -e "${RED}AWS CLI is not installed. Please install it and try again.${NC}"
        exit 1
    fi

    AWS_VERSION=$(aws --version | cut -d' ' -f1 | cut -d'/' -f2)
    if [[ $(echo -e "$AWS_VERSION\n2.24" | sort -V | head -n1) != "2.24" ]]; then
        echo -e "${RED}AWS CLI version is $AWS_VERSION, but 2.24 or higher is required.${NC}"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        echo -e "${RED}jq is not installed. Please install it and try again.${NC}"
        exit 1
    fi

    echo -e "${GREEN}All dependencies found.${NC}"
}

# Delete IAM role if it exists
delete_iam_role_if_exists() {
    local role_name=$1
    echo -e "${BLUE}Checking if IAM role $role_name exists...${NC}"

    if aws iam get-role --role-name $role_name &>/dev/null; then
        echo -e "${YELLOW}Role $role_name exists. Deleting...${NC}"

        # Get all attached policies
        local policies=$(aws iam list-attached-role-policies --role-name $role_name --query 'AttachedPolicies[*].PolicyArn' --output text)

        # Detach all policies
        for policy in $policies; do
            echo -e "${YELLOW}Detaching policy $policy from role $role_name...${NC}"
            debug_aws_command "aws iam detach-role-policy --role-name $role_name --policy-arn $policy"
            aws iam detach-role-policy --role-name $role_name --policy-arn $policy 2>/dev/null || true
        done

        # Try to delete the custom policy if it exists
        debug_aws_command "aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/StorybookPolicy"
        aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/StorybookPolicy 2>/dev/null || true

        # Delete the role
        debug_aws_command "aws iam delete-role --role-name $role_name"
        aws iam delete-role --role-name $role_name 2>/dev/null || true

        echo -e "${GREEN}Role $role_name deleted.${NC}"

        # Wait a bit for AWS to process the deletion
        echo -e "${YELLOW}Waiting 10 seconds for AWS to process the deletion...${NC}"
        sleep 10
    else
        echo -e "${GREEN}Role $role_name does not exist. Proceeding with creation.${NC}"
    fi
}

# Create IAM role for Bedrock Flow
create_iam_role() {
    echo -e "${BLUE}Creating IAM role for Bedrock Flow...${NC}"

    # Check and delete role if it exists
    delete_iam_role_if_exists $ROLE_NAME

    # Create trust policy
    cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "bedrock.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

    # Create policy document for Bedrock permissions
    cat > bedrock-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "bedrock:InvokeModel",
                "bedrock:InvokeAgent",
                "bedrock:Retrieve",
                "bedrock:ListRetrievers",
                "bedrock:RetrieveAndGenerate"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${FLOW_BUCKET_NAME}",
                "arn:aws:s3:::${FLOW_BUCKET_NAME}/*"
            ]
        }
    ]
}
EOF

    # Create the role
    debug_aws_command "aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://trust-policy.json"
    aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file://trust-policy.json

    # Create and attach policy
    debug_aws_command "aws iam create-policy --policy-name StorybookPolicy --policy-document file://bedrock-policy.json"
    aws iam create-policy \
        --policy-name StorybookPolicy \
        --policy-document file://bedrock-policy.json 2>/dev/null || true

    debug_aws_command "aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/StorybookPolicy"
    aws iam attach-role-policy \
        --role-name $ROLE_NAME \
        --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/StorybookPolicy

    # Wait for role to propagate
    echo -e "${YELLOW}Waiting 10 seconds for role to propagate...${NC}"
    sleep 10

    echo -e "${GREEN}IAM role created successfully.${NC}"

    # Clean up
    rm -f trust-policy.json bedrock-policy.json
}

# Delete S3 bucket if it exists
delete_s3_bucket_if_exists() {
    local bucket_name=$1
    echo -e "${BLUE}Checking if S3 bucket $bucket_name exists...${NC}"

    if aws s3api head-bucket --bucket $bucket_name 2>/dev/null; then
        echo -e "${YELLOW}S3 bucket $bucket_name exists. Deleting...${NC}"

        # Empty the bucket first
        debug_aws_command "aws s3 rm s3://${bucket_name} --recursive --region $REGION"
        aws s3 rm s3://${bucket_name} --recursive --region $REGION 2>/dev/null || true

        # Delete the bucket
        debug_aws_command "aws s3api delete-bucket --bucket ${bucket_name} --region $REGION"
        aws s3api delete-bucket --bucket ${bucket_name} --region $REGION 2>/dev/null || true

        echo -e "${GREEN}S3 bucket $bucket_name deleted.${NC}"

        # Wait a bit for AWS to process the deletion
        echo -e "${YELLOW}Waiting 5 seconds for AWS to process the deletion...${NC}"
        sleep 5
    else
        echo -e "${GREEN}S3 bucket $bucket_name does not exist. Proceeding with creation.${NC}"
    fi
}

# Create S3 bucket for storing resources
create_s3_bucket() {
    echo -e "${BLUE}Creating S3 bucket for flow resources...${NC}"

    # Check and delete bucket if it exists
    delete_s3_bucket_if_exists $FLOW_BUCKET_NAME

    # Create the bucket
    debug_aws_command "aws s3 mb s3://${FLOW_BUCKET_NAME} --region $REGION"
    aws s3 mb s3://${FLOW_BUCKET_NAME} --region $REGION

    # Enable versioning for backup
    debug_aws_command "aws s3api put-bucket-versioning --bucket ${FLOW_BUCKET_NAME} --versioning-configuration Status=Enabled"
    aws s3api put-bucket-versioning \
        --bucket ${FLOW_BUCKET_NAME} \
        --versioning-configuration Status=Enabled

    echo -e "${GREEN}S3 bucket created successfully.${NC}"
}

# Upload agent prompts to S3
upload_prompts() {
    echo -e "${BLUE}Creating and uploading agent prompts to S3...${NC}"

    mkdir -p prompts

    # Create prompts for all agents
    cat > prompts/executive_director.md << EOF
# Executive Director Agent Prompt

You are the Executive Director of a Storybook processing system. Your role is to:
- Orchestrate the entire workflow and coordinate all agents
- Maintain a global vision of Storybook goals and quality
- Make final decisions on major revisions
- Interface between the system and the human author

## INSTRUCTIONS:
1. Assess the Storybook's current state and identify the highest priority areas for improvement
2. Coordinate the work of all specialized agents in the system
3. Track overall progress and guide the Storybook through the revision process
4. Make executive decisions when agents have conflicting recommendations
5. Provide clear summaries to the human author of changes made and reasoning
6. Always maintain the original creative vision and voice of the Storybook

## Storybook ANALYSIS:
When analyzing a Storybook, consider:
- Overall narrative structure and flow
- Character development and arcs
- Pacing and engagement
- Thematic coherence
- Commercial viability
- Technical quality of writing

## OUTPUTS:
Provide concise, actionable guidance that includes:
1. Executive summary of Storybook status
2. Priority areas requiring attention
3. Specific instructions for specialized agents
4. Timeline for implementation
5. Clear rationale for decisions made

Remember that you hold the global vision for the Storybook. Focus on coordinating the specialized expertise of other agents while ensuring the final product maintains creative integrity and meets market standards.
EOF

    cat > prompts/creative_director.md << EOF
# Creative Director Agent Prompt

You are the Creative Director of a Storybook processing system. Your role is to:
- Define and protect core creative elements of the Storybook
- Balance commercial considerations with artistic integrity
- Guide stylistic decisions throughout the revision process
- Ensure the Storybook maintains its distinctive voice

## INSTRUCTIONS:
1. Identify the core creative elements that make this Storybook unique
2. Establish stylistic guidelines for all other agents to follow
3. Review proposed changes for creative consistency
4. Push back on suggestions that compromise artistic integrity
5. Enhance distinctive elements that set the Storybook apart
6. Ensure the author's original voice remains intact

## CREATIVE ASSESSMENT:
When reviewing a Storybook, analyze:
- Distinctive voice and tone
- Unique stylistic elements
- Core themes and motifs
- Artistic risks and innovations
- Genre conventions and subversions
- Emotional resonance

## OUTPUTS:
Provide clear creative guidance that includes:
1. Creative vision statement for the Storybook
2. Stylistic guidelines for maintaining voice consistency
3. Recommendations for enhancing distinctive elements
4. Identification of areas where commercial needs may conflict with artistic vision
5. Solutions that balance marketability with creative integrity

Remember that you are the guardian of the Storybook's artistic soul. Your decisions should protect what makes this work special while allowing necessary improvements to reach its full potential.
EOF

    # Create prompts for remaining agents (abbreviated for length)
    # In a full implementation, each agent would have a unique prompt
    for agent in "human_feedback_manager" "quality_assessment_director" "project_timeline_manager" "market_alignment_director" "structure_architect" "plot_development_specialist" "world_building_expert" "character_psychology_specialist" "character_voice_designer" "character_relationship_mapper" "domain_knowledge_specialist" "cultural_authenticity_expert" "content_development_director" "chapter_drafters" "scene_construction_specialists" "dialogue_crafters" "continuity_manager" "voice_consistency_monitor" "emotional_arc_designer" "editorial_director" "structural_editor" "character_arc_evaluator" "thematic_coherence_analyst" "prose_enhancement_specialist" "dialogue_refinement_expert" "rhythm_cadence_optimizer" "grammar_consistency_checker" "fact_verification_specialist" "positioning_specialist" "title_blurb_optimizer" "differentiation_strategist" "formatting_standards_expert"; do
        cat > prompts/${agent}.md << EOF
# ${agent^} Agent Prompt

You are the ${agent^} in a Storybook processing system. Your specialized role focuses on specific aspects of Storybook enhancement.

## INSTRUCTIONS:
1. Review the Storybook section with focus on your specialty
2. Identify issues and opportunities for improvement
3. Provide specific, actionable recommendations
4. Maintain consistency with the Storybook's voice and vision
5. Collaborate with other agents as needed

## ANALYSIS FOCUS:
[Specific analysis areas for this agent role]

## OUTPUTS:
Provide specialized recommendations including:
1. Identified issues in your domain expertise
2. Specific suggested improvements
3. Implementation guidance
4. Reasoning for recommendations

Remember to stay focused on your specific area of expertise while maintaining awareness of the Storybook's overall goals.
EOF
    done

    # Create text splitter utility
    cat > prompts/text_splitter.md << EOF
# Text Splitting Utility

You are a utility designed to split large Storybook texts into manageable chunks while preserving context.

## INSTRUCTIONS:
1. Split text at natural boundaries (chapters, scenes) whenever possible
2. Ensure each chunk contains enough context for processing
3. Maintain a small overlap between chunks for continuity
4. Track metadata including position in overall Storybook
5. Generate a brief summary of each chunk for reference

## PROCESS:
1. Identify natural break points
2. Create chunks of approximately 50,000 tokens or less
3. Include chapter/scene headers in chunks
4. Add contextual metadata to each chunk

## OUTPUT FORMAT:
For each chunk, provide:
1. Chunk ID and position information
2. Brief context summary (150 words max)
3. The chunk content itself
4. References to previous/next chunks

Ensure transitions between chunks maintain coherence and preserve the narrative flow.
EOF

    # Upload all prompts to S3
    debug_aws_command "aws s3 sync prompts/ s3://${FLOW_BUCKET_NAME}/prompts/ --region $REGION"
    aws s3 sync prompts/ s3://${FLOW_BUCKET_NAME}/prompts/ --region $REGION

    echo -e "${GREEN}Agent prompts uploaded successfully.${NC}"

    # Clean up
    rm -rf prompts
}

# Delete an agent and its aliases if they exist, with user confirmation
delete_agent_if_exists() {
    local agent_name=$1
    local existing_id=""
    local action=""
    local new_name=""

    echo -e "${BLUE}Checking if agent '$agent_name' already exists...${NC}"

    # List all agents and find one with matching name
    debug_aws_command "aws bedrock-agent list-agents --region $REGION"
    LIST_RESPONSE=$(aws bedrock-agent list-agents --region $REGION 2>/dev/null)

    if [ $? -eq 0 ]; then
        existing_id=$(echo $LIST_RESPONSE | jq -r ".agents[] | select(.displayName == \"$agent_name\") | .agentId" 2>/dev/null)

        if [ ! -z "$existing_id" ] && [ "$existing_id" != "null" ]; then
            echo -e "${YELLOW}Found existing agent '$agent_name' with ID: $existing_id.${NC}"

            # Give the user options
            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Delete existing agent and create a new one with the same name"
            echo -e "2. Use a different name for the new agent"
            echo -e "3. Cancel operation"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    action="delete"
                    echo -e "${YELLOW}Deleting existing agent '$agent_name'...${NC}"

                    # Check for aliases
                    debug_aws_command "aws bedrock-agent list-agent-aliases --agent-id $existing_id --region $REGION"
                    ALIAS_RESPONSE=$(aws bedrock-agent list-agent-aliases --agent-id $existing_id --region $REGION 2>/dev/null)

                    if [ $? -eq 0 ]; then
                        # Delete all aliases
                        alias_ids=$(echo $ALIAS_RESPONSE | jq -r '.agentAliases[].agentAliasId' 2>/dev/null)

                        for alias_id in $alias_ids; do
                            echo -e "${YELLOW}Deleting alias ID: $alias_id for agent '$agent_name'${NC}"
                            debug_aws_command "aws bedrock-agent delete-agent-alias --agent-id $existing_id --agent-alias-id $alias_id --region $REGION"
                            aws bedrock-agent delete-agent-alias --agent-id $existing_id --agent-alias-id $alias_id --region $REGION 2>/dev/null || true
                        done
                    fi

                    # Delete the agent
                    debug_aws_command "aws bedrock-agent delete-agent --agent-id $existing_id --skip-resource-in-use-check --region $REGION"
                    aws bedrock-agent delete-agent --agent-id $existing_id --skip-resource-in-use-check --region $REGION 2>/dev/null || true

                    echo -e "${GREEN}Deleted agent '$agent_name'${NC}"

                    # Wait for deletion to process
                    echo -e "${YELLOW}Waiting 5 seconds for agent deletion to process...${NC}"
                    sleep 5
                    ;;
                2)
                    action="rename"
                    read -p "Enter a new name for the agent: " new_name
                    echo -e "${GREEN}Will create agent with new name: '$new_name'${NC}"
                    ;;
                3)
                    action="cancel"
                    echo -e "${RED}Operation cancelled by user.${NC}"
                    ;;
                *)
                    action="cancel"
                    echo -e "${RED}Invalid option. Operation cancelled.${NC}"
                    ;;
            esac

            echo "action=$action" > /tmp/agent_action.txt
            echo "new_name=$new_name" >> /tmp/agent_action.txt

            if [ "$action" == "delete" ]; then
                return 0
            elif [ "$action" == "rename" ]; then
                return 2
            else
                return 1
            fi
        fi
    fi

    echo -e "${GREEN}No existing agent '$agent_name' found. Proceeding with creation.${NC}"
    return 0
}

# Wait for agent to be in a creatable state (not CREATING)
wait_for_agent_creatable() {
    local agent_id=$1
    local max_attempts=30
    local delay=10
    local attempt=0

    # Check if agent ID is valid
    if [ -z "$agent_id" ] || [ "$agent_id" == "null" ]; then
        echo -e "${RED}Invalid agent ID provided to wait_for_agent_creatable. Cannot proceed.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Waiting for agent to be in a valid state for preparation...${NC}"

    while ((attempt < max_attempts)); do
        debug_aws_command "aws bedrock-agent get-agent --agent-id $agent_id --region $REGION"
        GET_RESPONSE=$(aws bedrock-agent get-agent --agent-id $agent_id --region $REGION 2>/dev/null)

        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}Error getting agent status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        agent_status=$(echo $GET_RESPONSE | jq -r '.agent.agentStatus' 2>/dev/null)

        if [ -z "$agent_status" ] || [ "$agent_status" == "null" ]; then
            echo -e "${YELLOW}Could not extract agent status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        if [[ "$agent_status" != "CREATING" ]]; then
            echo -e "${GREEN}Agent is now in a valid state for preparation: $agent_status${NC}"
            return 0
        fi

        echo -e "${YELLOW}Agent status: $agent_status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
        sleep $delay
        attempt=$((attempt+1))
    done

    echo -e "${RED}Timed out waiting for agent to be in a valid state. Last status: $agent_status${NC}"
    return 1
}

# Wait for agent to be available with retries
wait_for_agent() {
    local agent_id=$1
    local max_attempts=30
    local delay=10
    local attempt=0

    # Check if agent ID is valid
    if [ -z "$agent_id" ] || [ "$agent_id" == "null" ]; then
        echo -e "${RED}Invalid agent ID provided to wait_for_agent. Cannot proceed.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Waiting for agent to be ready...${NC}"

    while ((attempt < max_attempts)); do
        debug_aws_command "aws bedrock-agent get-agent --agent-id $agent_id --region $REGION"
        GET_RESPONSE=$(aws bedrock-agent get-agent --agent-id $agent_id --region $REGION 2>/dev/null)

        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}Error getting agent status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        agent_status=$(echo $GET_RESPONSE | jq -r '.agent.agentStatus' 2>/dev/null)

        if [ -z "$agent_status" ] || [ "$agent_status" == "null" ]; then
            echo -e "${YELLOW}Could not extract agent status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        if [[ "$agent_status" == "PREPARED" || "$agent_status" == "AVAILABLE" ]]; then
            echo -e "${GREEN}Agent is now available with status: $agent_status${NC}"
            return 0
        fi

        echo -e "${YELLOW}Agent status: $agent_status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
        sleep $delay
        attempt=$((attempt+1))
    done

    echo -e "${RED}Timed out waiting for agent to be ready. Last status: $agent_status${NC}"
    return 1
}

# Wait for agent version to be available
wait_for_agent_version() {
    local agent_id=$1
    local version=$2
    local max_attempts=30
    local delay=10
    local attempt=0

    # Check if agent ID is valid
    if [ -z "$agent_id" ] || [ "$agent_id" == "null" ]; then
        echo -e "${RED}Invalid agent ID provided to wait_for_agent_version. Cannot proceed.${NC}"
        return 1
    fi

    # Check if version is valid
    if [ -z "$version" ] || [ "$version" == "null" ]; then
        echo -e "${RED}Invalid version provided to wait_for_agent_version. Cannot proceed.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Waiting for agent version to be ready...${NC}"

    while ((attempt < max_attempts)); do
        debug_aws_command "aws bedrock-agent get-agent-version --agent-id $agent_id --agent-version $version --region $REGION"
        GET_RESPONSE=$(aws bedrock-agent get-agent-version --agent-id $agent_id --agent-version $version --region $REGION 2>/dev/null)

        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}Error getting agent version status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        version_status=$(echo $GET_RESPONSE | jq -r '.agentVersionStatus' 2>/dev/null)

        if [ -z "$version_status" ] || [ "$version_status" == "null" ]; then
            echo -e "${YELLOW}Could not extract agent version status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        if [[ "$version_status" == "AVAILABLE" ]]; then
            echo -e "${GREEN}Agent version is now available with status: $version_status${NC}"
            return 0
        fi

        echo -e "${YELLOW}Agent version status: $version_status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
        sleep $delay
        attempt=$((attempt+1))
    done

    echo -e "${RED}Timed out waiting for agent version to be ready. Last status: $version_status${NC}"
    return 1
}

# Create agent function to reduce repetition
create_agent() {
    local agent_name=$1
    local agent_desc=$2
    local prompt_s3_path=$3
    local retry_count=0
    local max_retries=3
    local original_name=$agent_name

    echo -e "${BLUE}Creating agent: $agent_name...${NC}"

    while [ $retry_count -lt $max_retries ]; do
        # Check if agent already exists and ask user what to do
        delete_agent_if_exists "$agent_name"
        local delete_result=$?

        if [ $delete_result -eq 1 ]; then
            # User cancelled the operation
            echo -e "${RED}Agent creation cancelled by user.${NC}"
            return 1
        elif [ $delete_result -eq 2 ]; then
            # User wants to use a different name
            if [ -f /tmp/agent_action.txt ]; then
                source /tmp/agent_action.txt
                if [ ! -z "$new_name" ]; then
                    agent_name="$new_name"
                    echo -e "${BLUE}Using new name: $agent_name${NC}"
                fi
                rm -f /tmp/agent_action.txt
            fi
        fi

        # Read the prompt from S3 and pass it directly
        debug_aws_command "aws s3 cp s3://${FLOW_BUCKET_NAME}/${prompt_s3_path} prompt_content.md --region $REGION"
        aws s3 cp s3://${FLOW_BUCKET_NAME}/${prompt_s3_path} prompt_content.md --region $REGION

        if [ ! -f prompt_content.md ]; then
            echo -e "${RED}Failed to download prompt file from S3.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Retry"
            echo -e "2. Skip this agent"

            read -p "Choose an option (1/2): " choice

            case $choice in
                1)
                    retry_count=$((retry_count + 1))
                    echo -e "${YELLOW}Retrying... (Attempt $retry_count of $max_retries)${NC}"
                    continue
                    ;;
                *)
                    echo -e "${RED}Skipping agent creation.${NC}"
                    return 1
                    ;;
            esac
        fi

        prompt_content=$(cat prompt_content.md)

        # Create agent with Claude 3 Sonnet
        debug_aws_command "aws bedrock-agent create-agent --agent-name \"$agent_name\" --agent-resource-role-arn \"arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}\" --instruction \"$prompt_content\" --foundation-model \"$MODEL_ID\" --description \"$agent_desc\" --idle-session-ttl-in-seconds 1800 --region $REGION"
        RESPONSE=$(aws bedrock-agent create-agent \
            --agent-name "$agent_name" \
            --agent-resource-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
            --instruction "$prompt_content" \
            --foundation-model "$MODEL_ID" \
            --description "$agent_desc" \
            --idle-session-ttl-in-seconds 1800 \
            --region $REGION)

        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to create agent $agent_name.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Retry with the same name"
            echo -e "2. Try with a different name"
            echo -e "3. Skip this agent"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    retry_count=$((retry_count + 1))
                    echo -e "${YELLOW}Retrying... (Attempt $retry_count of $max_retries)${NC}"
                    ;;
                2)
                    read -p "Enter a new name for the agent: " agent_name
                    echo -e "${BLUE}Using new name: $agent_name${NC}"
                    retry_count=$((retry_count + 1))
                    ;;
                *)
                    echo -e "${RED}Skipping agent creation.${NC}"
                    rm -f prompt_content.md
                    return 1
                    ;;
            esac

            continue
        fi

        # Extract agent ID
        AGENT_ID=$(echo $RESPONSE | jq -r '.agent.agentId')

        if [ -z "$AGENT_ID" ] || [ "$AGENT_ID" == "null" ]; then
            echo -e "${RED}Failed to extract agent ID for $agent_name.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Retry"
            echo -e "2. Skip this agent"

            read -p "Choose an option (1/2): " choice

            case $choice in
                1)
                    retry_count=$((retry_count + 1))
                    echo -e "${YELLOW}Retrying... (Attempt $retry_count of $max_retries)${NC}"
                    ;;
                *)
                    echo -e "${RED}Skipping agent creation.${NC}"
                    rm -f prompt_content.md
                    return 1
                    ;;
            esac

            continue
        }

        AGENT_IDS["$original_name"]=$AGENT_ID  # Always store under the original name for consistency

        echo -e "${GREEN}Created agent: $agent_name with ID: $AGENT_ID${NC}"

        # Wait for agent to be in a valid state for preparation
        wait_for_agent_creatable $AGENT_ID

        if [ $? -ne 0 ]; then
            echo -e "${RED}Agent $agent_name is not in a valid state for preparation.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Continue anyway (skip prepare step)"
            echo -e "2. Retry"
            echo -e "3. Skip this agent"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    echo -e "${YELLOW}Continuing without preparing the agent.${NC}"
                    break  # Exit the retry loop
                    ;;
                2)
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "${YELLOW}Retrying... (Attempt $retry_count of $max_retries)${NC}"
                        continue
                    else
                        echo -e "${RED}Maximum retries reached. Continuing without preparing the agent.${NC}"
                        break  # Exit the retry loop
                    fi
                    ;;
                *)
                    echo -e "${RED}Skipping agent creation.${NC}"
                    rm -f prompt_content.md
                    return 1
                    ;;
            esac
        }

        # Prepare the agent with retry logic
        local prepare_attempts=5
        local prepare_delay=15
        local prepare_attempt=0
        local prepare_success=false

        while ((prepare_attempt < prepare_attempts)) && [[ "$prepare_success" == "false" ]]; do
            echo -e "${YELLOW}Attempting to prepare agent (attempt $((prepare_attempt+1))/$prepare_attempts)...${NC}"

            debug_aws_command "aws bedrock-agent prepare-agent --agent-id $AGENT_ID --region $REGION"
            if aws bedrock-agent prepare-agent --agent-id $AGENT_ID --region $REGION 2>/dev/null; then
                prepare_success=true
                echo -e "${GREEN}Successfully prepared agent.${NC}"
            else
                echo -e "${YELLOW}Failed to prepare agent. Waiting $prepare_delay seconds before retry...${NC}"
                sleep $prepare_delay
                prepare_attempt=$((prepare_attempt+1))
            fi
        done

        if [[ "$prepare_success" == "false" ]]; then
            echo -e "${YELLOW}Failed to prepare agent after $prepare_attempts attempts.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Continue anyway"
            echo -e "2. Retry agent creation"
            echo -e "3. Skip this agent"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    echo -e "${YELLOW}Continuing without properly prepared agent.${NC}"
                    break  # Exit the retry loop
                    ;;
                2)
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "${YELLOW}Retrying agent creation... (Attempt $retry_count of $max_retries)${NC}"
                        continue
                    else
                        echo -e "${RED}Maximum retries reached. Continuing with current agent state.${NC}"
                        break  # Exit the retry loop
                    fi
                    ;;
                *)
                    echo -e "${RED}Skipping agent creation.${NC}"
                    rm -f prompt_content.md
                    return 1
                    ;;
            esac
        }

        # Wait for agent to be ready
        wait_for_agent $AGENT_ID

        if [ $? -ne 0 ]; then
            echo -e "${RED}Agent $agent_name did not become ready.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Continue anyway (skip alias creation)"
            echo -e "2. Retry agent creation"
            echo -e "3. Skip this agent"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    echo -e "${YELLOW}Continuing without creating alias.${NC}"
                    rm -f prompt_content.md
                    return 0  # Consider the agent creation successful
                    ;;
                2)
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "${YELLOW}Retrying agent creation... (Attempt $retry_count of $max_retries)${NC}"
                        continue
                    else
                        echo -e "${RED}Maximum retries reached. Continuing without alias creation.${NC}"
                        rm -f prompt_content.md
                        return 0  # Consider the agent creation successful
                    fi
                    ;;
                *)
                    echo -e "${RED}Skipping agent creation.${NC}"
                    rm -f prompt_content.md
                    return 1
                    ;;
            esac
        }

        # Create agent alias with the created version
        debug_aws_command "aws bedrock-agent create-agent-alias --agent-id $AGENT_ID --agent-alias-name \"Production\" --region $REGION"
        ALIAS_RESPONSE=$(aws bedrock-agent create-agent-alias \
            --agent-id $AGENT_ID \
            --agent-alias-name "Production" \
            --region $REGION)

        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to create alias for agent $agent_name.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Retry alias creation"
            echo -e "2. Continue without alias"

            read -p "Choose an option (1/2): " choice

            case $choice in
                1)
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "${YELLOW}Retrying alias creation... (Attempt $retry_count of $max_retries)${NC}"
                        continue
                    else
                        echo -e "${RED}Maximum retries reached. Continuing without alias.${NC}"
                        rm -f prompt_content.md
                        return 0  # Consider the agent creation successful
                    fi
                    ;;
                *)
                    echo -e "${YELLOW}Continuing without alias.${NC}"
                    rm -f prompt_content.md
                    return 0  # Consider the agent creation successful
                    ;;
            esac
        }

        # Extract alias ID
        ALIAS_ID=$(echo $ALIAS_RESPONSE | jq -r '.agentAlias.agentAliasId')

        echo -e "${GREEN}Created alias for $agent_name${NC}"
        echo -e "${GREEN}Agent $agent_name is ready${NC}"

        # Clean up temporary file
        rm -f prompt_content.md

        # We've successfully created the agent, so exit the retry loop
        break
    }

    if [ $retry_count -ge $max_retries ]; then
        echo -e "${RED}Maximum retries reached for agent $original_name.${NC}"
        return 1
    fi

    return 0
}

# Create all agents in the system
create_agents() {
    echo -e "${BLUE}Creating all agents for Storybook processing workflow...${NC}"

    # Create Executive Tier Agents
    create_agent "ExecutiveDirector" "System orchestrator and final decision-maker" "prompts/executive_director.md"
    create_agent "CreativeDirector" "Guardian of the Storybook's artistic vision" "prompts/creative_director.md"
    create_agent "HumanFeedbackManager" "Interpreter of author intentions and external feedback" "prompts/human_feedback_manager.md"
    create_agent "QualityAssessmentDirector" "Objective evaluator of Storybook progression" "prompts/quality_assessment_director.md"
    create_agent "ProjectTimelineManager" "Process efficiency expert" "prompts/project_timeline_manager.md"
    create_agent "MarketAlignmentDirector" "Commercial viability specialist" "prompts/market_alignment_director.md"

    # Create Structural Tier Agents
    create_agent "StructureArchitect" "Master blueprint designer" "prompts/structure_architect.md"
    create_agent "PlotDevelopmentSpecialist" "Narrative progression expert" "prompts/plot_development_specialist.md"
    create_agent "WorldBuildingExpert" "Setting and environment specialist" "prompts/world_building_expert.md"
    create_agent "CharacterPsychologySpecialist" "Character motivation and behavior expert" "prompts/character_psychology_specialist.md"
    create_agent "CharacterVoiceDesigner" "Dialogue and narration differentiation expert" "prompts/character_voice_designer.md"
    create_agent "CharacterRelationshipMapper" "Interpersonal dynamics specialist" "prompts/character_relationship_mapper.md"
    create_agent "DomainKnowledgeSpecialist" "Subject matter accuracy expert" "prompts/domain_knowledge_specialist.md"
    create_agent "CulturalAuthenticityExpert" "Cultural representation specialist" "prompts/cultural_authenticity_expert.md"

    # Create Content Development Tier Agents
    create_agent "ContentDevelopmentDirector" "Manager of content creation processes" "prompts/content_development_director.md"
    create_agent "ChapterDrafters" "Chapter-level content specialists" "prompts/chapter_drafters.md"
    create_agent "SceneConstructionSpecialists" "Scene-level narrative engineers" "prompts/scene_construction_specialists.md"
    create_agent "DialogueCrafters" "Conversation optimization experts" "prompts/dialogue_crafters.md"
    create_agent "ContinuityManager" "Consistency enforcement specialist" "prompts/continuity_manager.md"
    create_agent "VoiceConsistencyMonitor" "Stylistic uniformity specialist" "prompts/voice_consistency_monitor.md"
    create_agent "EmotionalArcDesigner" "Reader emotional experience architect" "prompts/emotional_arc_designer.md"

    # Create Editorial Tier Agents
    create_agent "EditorialDirector" "Master editor overseeing all refinement" "prompts/editorial_director.md"
    create_agent "StructuralEditor" "Narrative structure refinement specialist" "prompts/structural_editor.md"
    create_agent "CharacterArcEvaluator" "Character development trajectory specialist" "prompts/character_arc_evaluator.md"
    create_agent "ThematicCoherenceAnalyst" "Theme development specialist" "prompts/thematic_coherence_analyst.md"
    create_agent "ProseEnhancementSpecialist" "Sentence-level writing expert" "prompts/prose_enhancement_specialist.md"
    create_agent "DialogueRefinementExpert" "Conversation quality specialist" "prompts/dialogue_refinement_expert.md"
    create_agent "RhythmCadenceOptimizer" "Prose musicality specialist" "prompts/rhythm_cadence_optimizer.md"
    create_agent "GrammarConsistencyChecker" "Technical correctness specialist" "prompts/grammar_consistency_checker.md"
    create_agent "FactVerificationSpecialist" "Accuracy confirmation expert" "prompts/fact_verification_specialist.md"

    # Create Market Positioning Tier Agents
    create_agent "PositioningSpecialist" "Market placement strategist" "prompts/positioning_specialist.md"
    create_agent "TitleBlurbOptimizer" "First impression enhancement expert" "prompts/title_blurb_optimizer.md"
    create_agent "DifferentiationStrategist" "Uniqueness enhancement specialist" "prompts/differentiation_strategist.md"
    create_agent "FormattingStandardsExpert" "Industry standards compliance specialist" "prompts/formatting_standards_expert.md"

    # Create utility agent for text splitting
    create_agent "TextSplitter" "Utility for splitting large Storybooks" "prompts/text_splitter.md"

    echo -e "${GREEN}All agents created successfully.${NC}"

    # Save agent IDs to file for later use
    echo "Saving agent IDs to file for reference..."
    declare -p AGENT_IDS > agent_ids.txt
}

# Delete a flow and its aliases if they exist, with user confirmation
delete_flow_if_exists() {
    local flow_name=$1
    local existing_id=""
    local action=""
    local new_name=""

    echo -e "${BLUE}Checking if flow '$flow_name' already exists...${NC}"

    # List all flows and find one with matching name
    debug_aws_command "aws bedrock-agent list-flows --region $REGION"
    LIST_RESPONSE=$(aws bedrock-agent list-flows --region $REGION 2>/dev/null)

    if [ $? -eq 0 ]; then
        # Updated to use flowSummaries instead of flows
        existing_id=$(echo $LIST_RESPONSE | jq -r ".flowSummaries[] | select(.name == \"$flow_name\") | .id" 2>/dev/null)

        if [ ! -z "$existing_id" ] && [ "$existing_id" != "null" ]; then
            echo -e "${YELLOW}Found existing flow '$flow_name' with ID: $existing_id.${NC}"

            # Give the user options
            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Delete existing flow and create a new one with the same name"
            echo -e "2. Use a different name for the new flow"
            echo -e "3. Cancel operation"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    action="delete"
                    echo -e "${YELLOW}Deleting existing flow '$flow_name'...${NC}"

                    # Check for aliases
                    debug_aws_command "aws bedrock-agent list-flow-aliases --flow-identifier $existing_id --region $REGION"
                    ALIAS_RESPONSE=$(aws bedrock-agent list-flow-aliases --flow-identifier $existing_id --region $REGION 2>/dev/null)

                    if [ $? -eq 0 ]; then
                        # Updated to use flowAliasSummaries instead of flowAliases
                        alias_ids=$(echo $ALIAS_RESPONSE | jq -r '.flowAliasSummaries[].id' 2>/dev/null)

                        for alias_id in $alias_ids; do
                            if [ ! -z "$alias_id" ] && [ "$alias_id" != "null" ]; then
                                echo -e "${YELLOW}Deleting flow alias ID: $alias_id for flow '$flow_name'${NC}"
                                # Updated to use alias-identifier instead of flow-alias-id
                                debug_aws_command "aws bedrock-agent delete-flow-alias --flow-identifier $existing_id --alias-identifier $alias_id --region $REGION"
                                aws bedrock-agent delete-flow-alias --flow-identifier $existing_id --alias-identifier $alias_id --region $REGION 2>/dev/null || true
                            fi
                        done
                    fi

                    # Delete the flow
                    debug_aws_command "aws bedrock-agent delete-flow --flow-identifier $existing_id --region $REGION"
                    aws bedrock-agent delete-flow --flow-identifier $existing_id --region $REGION 2>/dev/null || true

                    echo -e "${GREEN}Deleted flow '$flow_name'${NC}"

                    # Wait for deletion to process
                    echo -e "${YELLOW}Waiting 5 seconds for flow deletion to process...${NC}"
                    sleep 5
                    ;;
                2)
                    action="rename"
                    read -p "Enter a new name for the flow: " new_name
                    echo -e "${GREEN}Will create flow with new name: '$new_name'${NC}"
                    ;;
                3)
                    action="cancel"
                    echo -e "${RED}Operation cancelled by user.${NC}"
                    ;;
                *)
                    action="cancel"
                    echo -e "${RED}Invalid option. Operation cancelled.${NC}"
                    ;;
            esac

            echo "action=$action" > /tmp/flow_action.txt
            echo "new_name=$new_name" >> /tmp/flow_action.txt

            if [ "$action" == "delete" ]; then
                return 0
            elif [ "$action" == "rename" ]; then
                return 2
            else
                return 1
            fi
        fi
    fi

    echo -e "${GREEN}No existing flow '$flow_name' found. Proceeding with creation.${NC}"
    return 0
}

# Wait for flow to be in a valid state for preparation
wait_for_flow_creatable() {
    local flow_id=$1
    local max_attempts=30
    local delay=10
    local attempt=0

    # Check if flow ID is valid
    if [ -z "$flow_id" ] || [ "$flow_id" == "null" ]; then
        echo -e "${RED}Invalid flow ID provided to wait_for_flow_creatable. Cannot proceed.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Waiting for flow to be in a valid state for preparation...${NC}"

    while ((attempt < max_attempts)); do
        debug_aws_command "aws bedrock-agent get-flow --flow-identifier $flow_id --region $REGION"
        GET_RESPONSE=$(aws bedrock-agent get-flow --flow-identifier $flow_id --region $REGION 2>/dev/null)

        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}Error getting flow status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        flow_status=$(echo $GET_RESPONSE | jq -r '.status' 2>/dev/null)

        if [ -z "$flow_status" ] || [ "$flow_status" == "null" ]; then
            echo -e "${YELLOW}Could not extract flow status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        if [[ "$flow_status" != "CREATING" ]]; then
            echo -e "${GREEN}Flow is now in a valid state for preparation: $flow_status${NC}"
            return 0
        fi

        echo -e "${YELLOW}Flow status: $flow_status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
        sleep $delay
        attempt=$((attempt+1))
    done

    echo -e "${RED}Timed out waiting for flow to be in a valid state. Last status: $flow_status${NC}"
    return 1
}

# Wait for flow version to be available
wait_for_flow_version() {
    local flow_id=$1
    local version=$2
    local max_attempts=30
    local delay=10
    local attempt=0

    # Check if flow ID is valid
    if [ -z "$flow_id" ] || [ "$flow_id" == "null" ]; then
        echo -e "${RED}Invalid flow ID provided to wait_for_flow_version. Cannot proceed.${NC}"
        return 1
    fi

    # Check if version is valid
    if [ -z "$version" ] || [ "$version" == "null" ]; then
        echo -e "${RED}Invalid version provided to wait_for_flow_version. Cannot proceed.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Waiting for flow version to be ready...${NC}"

    while ((attempt < max_attempts)); do
        debug_aws_command "aws bedrock-agent get-flow-version --flow-identifier $flow_id --flow-version $version --region $REGION"
        GET_RESPONSE=$(aws bedrock-agent get-flow-version --flow-identifier $flow_id --flow-version $version --region $REGION 2>/dev/null)

        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}Error getting flow version status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        version_status=$(echo $GET_RESPONSE | jq -r '.status' 2>/dev/null)

        if [ -z "$version_status" ] || [ "$version_status" == "null" ]; then
            echo -e "${YELLOW}Could not extract flow version status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        if [[ "$version_status" == "AVAILABLE" ]]; then
            echo -e "${GREEN}Flow version is now available with status: $version_status${NC}"
            return 0
        fi

        echo -e "${YELLOW}Flow version status: $version_status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
        sleep $delay
        attempt=$((attempt+1))
    done

    echo -e "${RED}Timed out waiting for flow version to be ready. Last status: $version_status${NC}"
    return 1
}

# Create the Bedrock Flow
create_flow() {
    local flow_name="storybook"  # Default name
    local retry_count=0
    local max_retries=3

    echo -e "${BLUE}Creating Bedrock Flow for Storybook processing...${NC}"

    while [ $retry_count -lt $max_retries ]; do
        # Check if flow already exists and ask user what to do
        delete_flow_if_exists "$flow_name"
        local delete_result=$?

        if [ $delete_result -eq 1 ]; then
            # User cancelled the operation
            echo -e "${RED}Flow creation cancelled by user.${NC}"
            return 1
        elif [ $delete_result -eq 2 ]; then
            # User wants to use a different name
            if [ -f /tmp/flow_action.txt ]; then
                source /tmp/flow_action.txt
                if [ ! -z "$new_name" ]; then
                    flow_name="$new_name"
                    echo -e "${BLUE}Using new name: $flow_name${NC}"
                fi
                rm -f /tmp/flow_action.txt
            fi
        fi

        # Create a template for the flow definition with placeholders for agent ARNs
        cat > flow_definition.json << EOF
{
  "connections": [
    {
      "configuration": {
        "data": {
          "sourceOutput": "document",
          "targetInput": "agentInputText"
        }
      },
      "name": "InputToTextSplitter",
      "source": "InputNode",
      "target": "textsplitter_node",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "agentInputText"
        }
      },
      "name": "TextSplitterToExecutive",
      "source": "textsplitter_node",
      "target": "ExecutiveAssessment",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "agentInputText"
        }
      },
      "name": "ExecutiveToCreative",
      "source": "ExecutiveAssessment",
      "target": "CreativeVision",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "agentInputText"
        }
      },
      "name": "CreativeToMarket",
      "source": "CreativeVision",
      "target": "MarketAnalysis",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "agentInputText"
        }
      },
      "name": "MarketToStructural",
      "source": "MarketAnalysis",
      "target": "structural_assessment",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "agentInputText"
        }
      },
      "name": "StructuralToCharacter",
      "source": "structural_assessment",
      "target": "character_assessment",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "agentInputText"
        }
      },
      "name": "CharacterToContent",
      "source": "character_assessment",
      "target": "content_refinement",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "agentInputText"
        }
      },
      "name": "ContentToEditorial",
      "source": "content_refinement",
      "target": "editorial_direction",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "agentInputText"
        }
      },
      "name": "EditorialToProse",
      "source": "editorial_direction",
      "target": "prose_refinement",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "agentInputText"
        }
      },
      "name": "ProseToFinal",
      "source": "prose_refinement",
      "target": "final_revision",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "document"
        }
      },
      "name": "FinalToOutput",
      "source": "final_revision",
      "target": "OutputNode",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "executiveSummary"
        }
      },
      "name": "ExecutiveToOutput",
      "source": "ExecutiveAssessment",
      "target": "OutputNode",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "creativeVision"
        }
      },
      "name": "CreativeToOutput",
      "source": "CreativeVision",
      "target": "OutputNode",
      "type": "Data"
    },
    {
      "configuration": {
        "data": {
          "sourceOutput": "agentResponse",
          "targetInput": "marketAnalysis"
        }
      },
      "name": "MarketToOutput",
      "source": "MarketAnalysis",
      "target": "OutputNode",
      "type": "Data"
    }
  ],
  "nodes": [
    {
      "configuration": {
        "input": {}
      },
      "name": "InputNode",
      "outputs": [
        {
          "name": "document",
          "type": "String"
        }
      ],
      "type": "Input"
    },
    {
      "configuration": {
        "agent": {
          "agentAliasArn": "AGENT_TEXTSPLITTER_ARN"
        }
      },
      "inputs": [
        {
          "expression": "$.data.document",
          "name": "agentInputText",
          "type": "String"
        }
      ],
      "name": "textsplitter_node",
      "outputs": [
        {
          "name": "agentResponse",
          "type": "String"
        }
      ],
      "type": "Agent"
    },
    {
      "configuration": {
        "agent": {
          "agentAliasArn": "AGENT_EXECUTIVEDIRECTOR_ARN"
        }
      },
      "inputs": [
        {
          "expression": "$.data.agentInputText",
          "name": "agentInputText",
          "type": "String"
        }
      ],
      "name": "ExecutiveAssessment",
      "outputs": [
        {
          "name": "agentResponse",
          "type": "String"
        }
      ],
      "type": "Agent"
    },
    {
      "configuration": {
        "agent": {
          "agentAliasArn": "AGENT_CREATIVEDIRECTOR_ARN"
        }
      },
      "inputs": [
        {
          "expression": "$.data.agentInputText",
          "name": "agentInputText",
          "type": "String"
        }
      ],
      "name": "CreativeVision",
      "outputs": [
        {
          "name": "agentResponse",
          "type": "String"
        }
      ],
      "type": "Agent"
    },
    {
      "configuration": {
        "agent": {
          "agentAliasArn": "AGENT_MARKETALIGNMENTDIRECTOR_ARN"
        }
      },
      "inputs": [
        {
          "expression": "$.data.agentInputText",
          "name": "agentInputText",
          "type": "String"
        }
      ],
      "name": "MarketAnalysis",
      "outputs": [
        {
          "name": "agentResponse",
          "type": "String"
        }
      ],
      "type": "Agent"
    },
    {
      "configuration": {
        "agent": {
          "agentAliasArn": "AGENT_STRUCTUREARCHITECT_ARN"
        }
      },
      "inputs": [
        {
          "expression": "$.data.agentInputText",
          "name": "agentInputText",
          "type": "String"
        }
      ],
      "name": "structural_assessment",
      "outputs": [
        {
          "name": "agentResponse",
          "type": "String"
        }
      ],
      "type": "Agent"
    },
    {
      "configuration": {
        "agent": {
          "agentAliasArn": "AGENT_CHARACTERPSYCHOLOGYSPECIALIST_ARN"
        }
      },
      "inputs": [
        {
          "expression": "$.data.agentInputText",
          "name": "agentInputText",
          "type": "String"
        }
      ],
      "name": "character_assessment",
      "outputs": [
        {
          "name": "agentResponse",
          "type": "String"
        }
      ],
      "type": "Agent"
    },
    {
      "configuration": {
        "agent": {
          "agentAliasArn": "AGENT_CONTENTDEVELOPMENTDIRECTOR_ARN"
        }
      },
      "inputs": [
        {
          "expression": "$.data.agentInputText",
          "name": "agentInputText",
          "type": "String"
        }
      ],
      "name": "content_refinement",
      "outputs": [
        {
          "name": "agentResponse",
          "type": "String"
        }
      ],
      "type": "Agent"
    },
    {
      "configuration": {
        "agent": {
          "agentAliasArn": "AGENT_EDITORIALDIRECTOR_ARN"
        }
      },
      "inputs": [
        {
          "expression": "$.data.agentInputText",
          "name": "agentInputText",
          "type": "String"
        }
      ],
      "name": "editorial_direction",
      "outputs": [
        {
          "name": "agentResponse",
          "type": "String"
        }
      ],
      "type": "Agent"
    },
    {
      "configuration": {
        "agent": {
          "agentAliasArn": "AGENT_PROSEENHANCEMENTSPECIALIST_ARN"
        }
      },
      "inputs": [
        {
          "expression": "$.data.agentInputText",
          "name": "agentInputText",
          "type": "String"
        }
      ],
      "name": "prose_refinement",
      "outputs": [
        {
          "name": "agentResponse",
          "type": "String"
        }
      ],
      "type": "Agent"
    },
    {
      "configuration": {
        "agent": {
          "agentAliasArn": "AGENT_EXECUTIVEDIRECTOR_ARN"
        }
      },
      "inputs": [
        {
          "expression": "$.data.agentInputText",
          "name": "agentInputText",
          "type": "String"
        }
      ],
      "name": "final_revision",
      "outputs": [
        {
          "name": "agentResponse",
          "type": "String"
        }
      ],
      "type": "Agent"
    },
    {
      "configuration": {
        "output": {}
      },
      "inputs": [
        {
          "expression": "$.data.document",
          "name": "document",
          "type": "String"
        },
        {
          "expression": "$.data.executiveSummary",
          "name": "executiveSummary",
          "type": "String"
        },
        {
          "expression": "$.data.creativeVision",
          "name": "creativeVision",
          "type": "String"
        },
        {
          "expression": "$.data.marketAnalysis",
          "name": "marketAnalysis",
          "type": "String"
        }
      ],
      "name": "OutputNode",
      "outputs": [],
      "type": "Output"
    }
  ]
}
EOF

        # Validate each agent ID before replacing in the template
        for agent_name in "TextSplitter" "ExecutiveDirector" "CreativeDirector" "MarketAlignmentDirector" "StructureArchitect" "CharacterPsychologySpecialist" "ContentDevelopmentDirector" "EditorialDirector" "ProseEnhancementSpecialist"; do
            if [ -z "${AGENT_IDS[$agent_name]}" ]; then
                echo -e "${RED}Missing agent ID for $agent_name. Cannot create flow.${NC}"

                echo -e "${BLUE}Options:${NC}"
                echo -e "1. Retry after checking agent creation"
                echo -e "2. Cancel flow creation"

                read -p "Choose an option (1/2): " choice

                case $choice in
                    1)
                        retry_count=$((retry_count + 1))
                        if [ $retry_count -lt $max_retries ]; then
                            echo -e "${YELLOW}Retrying... (Attempt $retry_count of $max_retries)${NC}"
                            rm -f flow_definition.json
                            continue
                        else
                            echo -e "${RED}Maximum retries reached. Cancelling flow creation.${NC}"
                            rm -f flow_definition.json
                            return 1
                        fi
                        ;;
                    *)
                        echo -e "${RED}Flow creation cancelled.${NC}"
                        rm -f flow_definition.json
                        return 1
                        ;;
                esac
            fi
        done

        # Replace placeholders with actual agent alias ARNs
        textsplitter_arn="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:agent-alias/${AGENT_IDS["TextSplitter"]}/Production"
        sed -i "s|AGENT_TEXTSPLITTER_ARN|$textsplitter_arn|g" flow_definition.json

        executive_arn="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:agent-alias/${AGENT_IDS["ExecutiveDirector"]}/Production"
        sed -i "s|AGENT_EXECUTIVEDIRECTOR_ARN|$executive_arn|g" flow_definition.json

        creative_arn="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:agent-alias/${AGENT_IDS["CreativeDirector"]}/Production"
        sed -i "s|AGENT_CREATIVEDIRECTOR_ARN|$creative_arn|g" flow_definition.json

        market_arn="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:agent-alias/${AGENT_IDS["MarketAlignmentDirector"]}/Production"
        sed -i "s|AGENT_MARKETALIGNMENTDIRECTOR_ARN|$market_arn|g" flow_definition.json

        structure_arn="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:agent-alias/${AGENT_IDS["StructureArchitect"]}/Production"
        sed -i "s|AGENT_STRUCTUREARCHITECT_ARN|$structure_arn|g" flow_definition.json

        character_arn="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:agent-alias/${AGENT_IDS["CharacterPsychologySpecialist"]}/Production"
        sed -i "s|AGENT_CHARACTERPSYCHOLOGYSPECIALIST_ARN|$character_arn|g" flow_definition.json

        content_arn="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:agent-alias/${AGENT_IDS["ContentDevelopmentDirector"]}/Production"
        sed -i "s|AGENT_CONTENTDEVELOPMENTDIRECTOR_ARN|$content_arn|g" flow_definition.json

        editorial_arn="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:agent-alias/${AGENT_IDS["EditorialDirector"]}/Production"
        sed -i "s|AGENT_EDITORIALDIRECTOR_ARN|$editorial_arn|g" flow_definition.json

        prose_arn="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:agent-alias/${AGENT_IDS["ProseEnhancementSpecialist"]}/Production"
        sed -i "s|AGENT_PROSEENHANCEMENTSPECIALIST_ARN|$prose_arn|g" flow_definition.json

        # Create the flow
        debug_aws_command "aws bedrock-agent create-flow --name \"$flow_name\" --definition file://flow_definition.json --execution-role-arn \"arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}\" --region $REGION"
        FLOW_RESPONSE=$(aws bedrock-agent create-flow \
            --name "$flow_name" \
            --definition file://flow_definition.json \
            --execution-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
            --region $REGION)

        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to create flow.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Retry with the same name"
            echo -e "2. Try with a different name"
            echo -e "3. Cancel flow creation"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "${YELLOW}Retrying... (Attempt $retry_count of $max_retries)${NC}"
                        rm -f flow_definition.json
                        continue
                    else
                        echo -e "${RED}Maximum retries reached. Cancelling flow creation.${NC}"
                        rm -f flow_definition.json
                        return 1
                    fi
                    ;;
                2)
                    read -p "Enter a new name for the flow: " flow_name
                    echo -e "${BLUE}Using new name: $flow_name${NC}"
                    retry_count=$((retry_count + 1))
                    rm -f flow_definition.json
                    continue
                    ;;
                *)
                    echo -e "${RED}Flow creation cancelled.${NC}"
                    rm -f flow_definition.json
                    return 1
                    ;;
            esac
        }

        # Extract flow ID
        FLOW_ID=$(echo $FLOW_RESPONSE | jq -r '.id')

        if [ -z "$FLOW_ID" ] || [ "$FLOW_ID" == "null" ]; then
            echo -e "${RED}Failed to extract flow ID.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Retry flow creation"
            echo -e "2. Cancel flow creation"

            read -p "Choose an option (1/2): " choice

            case $choice in
                1)
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "${YELLOW}Retrying... (Attempt $retry_count of $max_retries)${NC}"
                        rm -f flow_definition.json
                        continue
                    else
                        echo -e "${RED}Maximum retries reached. Cancelling flow creation.${NC}"
                        rm -f flow_definition.json
                        return 1
                    fi
                    ;;
                *)
                    echo -e "${RED}Flow creation cancelled.${NC}"
                    rm -f flow_definition.json
                    return 1
                    ;;
            esac
        }

        echo -e "${GREEN}Created flow with ID: $FLOW_ID${NC}"

        # Wait for flow to be in a valid state for preparation
        wait_for_flow_creatable $FLOW_ID

        if [ $? -ne 0 ]; then
            echo -e "${RED}Flow is not in a valid state for preparation.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Retry flow creation"
            echo -e "2. Continue anyway (at your own risk)"
            echo -e "3. Cancel flow creation"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "${YELLOW}Retrying... (Attempt $retry_count of $max_retries)${NC}"
                        rm -f flow_definition.json
                        continue
                    else
                        echo -e "${RED}Maximum retries reached. Cancelling flow creation.${NC}"
                        rm -f flow_definition.json
                        return 1
                    fi
                    ;;
                2)
                    echo -e "${YELLOW}Continuing despite flow not being in a valid state.${NC}"
                    ;;
                *)
                    echo -e "${RED}Flow creation cancelled.${NC}"
                    rm -f flow_definition.json
                    return 1
                    ;;
            esac
        }

        # Prepare the flow with retry logic
        local prepare_attempts=5
        local prepare_delay=15
        local prepare_attempt=0
        local prepare_success=false

        while ((prepare_attempt < prepare_attempts)) && [[ "$prepare_success" == "false" ]]; do
            echo -e "${YELLOW}Attempting to prepare flow (attempt $((prepare_attempt+1))/$prepare_attempts)...${NC}"

            debug_aws_command "aws bedrock-agent prepare-flow --flow-identifier $FLOW_ID --region $REGION"
            if aws bedrock-agent prepare-flow --flow-identifier $FLOW_ID --region $REGION 2>/dev/null; then
                prepare_success=true
                echo -e "${GREEN}Successfully prepared flow.${NC}"
            else
                echo -e "${YELLOW}Failed to prepare flow. Waiting $prepare_delay seconds before retry...${NC}"
                sleep $prepare_delay
                prepare_attempt=$((prepare_attempt+1))
            fi
        done

        if [[ "$prepare_success" == "false" ]]; then
            echo -e "${YELLOW}Failed to prepare flow after $prepare_attempts attempts.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Continue anyway (at your own risk)"
            echo -e "2. Retry flow creation"
            echo -e "3. Cancel flow creation"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    echo -e "${YELLOW}Continuing without properly prepared flow.${NC}"
                    ;;
                2)
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "${YELLOW}Retrying flow creation... (Attempt $retry_count of $max_retries)${NC}"
                        rm -f flow_definition.json
                        continue
                    else
                        echo -e "${RED}Maximum retries reached. Cancelling flow creation.${NC}"
                        rm -f flow_definition.json
                        return 1
                    fi
                    ;;
                *)
                    echo -e "${RED}Flow creation cancelled.${NC}"
                    rm -f flow_definition.json
                    return 1
                    ;;
            esac
        }

        # Create a version from the DRAFT state with retry logic
        local version_attempts=5
        local version_delay=15
        local version_attempt=0
        local version_success=false
        local FLOW_VERSION=""

        while ((version_attempt < version_attempts)) && [[ "$version_success" == "false" ]]; do
            echo -e "${YELLOW}Attempting to create flow version (attempt $((version_attempt+1))/$version_attempts)...${NC}"

            debug_aws_command "aws bedrock-agent create-flow-version --flow-identifier $FLOW_ID --region $REGION"
            FLOW_VERSION_RESPONSE=$(aws bedrock-agent create-flow-version --flow-identifier $FLOW_ID --region $REGION 2>/dev/null)

            if [ $? -eq 0 ]; then
                version_success=true
                FLOW_VERSION=$(echo $FLOW_VERSION_RESPONSE | jq -r '.version')
                echo -e "${GREEN}Successfully created flow version: $FLOW_VERSION${NC}"
            else
                echo -e "${YELLOW}Failed to create flow version. Waiting $version_delay seconds before retry...${NC}"
                sleep $version_delay
                version_attempt=$((version_attempt+1))
            fi
        done

        if [[ "$version_success" == "false" ]]; then
            echo -e "${RED}Failed to create flow version after $version_attempts attempts.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Retry flow creation"
            echo -e "2. Cancel flow creation"

            read -p "Choose an option (1/2): " choice

            case $choice in
                1)
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "${YELLOW}Retrying flow creation... (Attempt $retry_count of $max_retries)${NC}"
                        rm -f flow_definition.json
                        continue
                    else
                        echo -e "${RED}Maximum retries reached. Cancelling flow creation.${NC}"
                        rm -f flow_definition.json
                        return 1
                    fi
                    ;;
                *)
                    echo -e "${RED}Flow creation cancelled.${NC}"
                    rm -f flow_definition.json
                    return 1
                    ;;
            esac
        }

        # Wait for flow version to be ready
        wait_for_flow_version $FLOW_ID $FLOW_VERSION

        if [ $? -ne 0 ]; then
            echo -e "${RED}Flow version did not become ready.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Continue anyway (skip alias creation)"
            echo -e "2. Retry flow creation"
            echo -e "3. Cancel flow creation"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    echo -e "${YELLOW}Continuing without creating alias.${NC}"
                    rm -f flow_definition.json
                    # Skip alias creation and return
                    echo "FLOW_ID=$FLOW_ID" > flow_info.txt
                    echo "FLOW_VERSION=$FLOW_VERSION" >> flow_info.txt
                    echo -e "${GREEN}Flow created with ID: $FLOW_ID${NC}"
                    return 0
                    ;;
                2)
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "${YELLOW}Retrying flow creation... (Attempt $retry_count of $max_retries)${NC}"
                        rm -f flow_definition.json
                        continue
                    else
                        echo -e "${RED}Maximum retries reached. Continuing without alias creation.${NC}"
                        rm -f flow_definition.json
                        echo "FLOW_ID=$FLOW_ID" > flow_info.txt
                        echo "FLOW_VERSION=$FLOW_VERSION" >> flow_info.txt
                        echo -e "${GREEN}Flow created with ID: $FLOW_ID${NC}"
                        return 0
                    fi
                    ;;
                *)
                    echo -e "${RED}Flow creation cancelled.${NC}"
                    rm -f flow_definition.json
                    return 1
                    ;;
            esac
        }

        # Create flow alias with the created version - using a file for routing config
        cat > routing_config.json << EOF
[{"flowVersion":"$FLOW_VERSION"}]
EOF

        debug_aws_command "aws bedrock-agent create-flow-alias --flow-identifier $FLOW_ID --name \"Production\" --routing-configuration file://routing_config.json --region $REGION"
        FLOW_ALIAS_RESPONSE=$(aws bedrock-agent create-flow-alias \
            --flow-identifier $FLOW_ID \
            --name "Production" \
            --routing-configuration file://routing_config.json \
            --region $REGION)

        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to create flow alias.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Retry alias creation"
            echo -e "2. Continue without alias"
            echo -e "3. Cancel flow creation"

            read -p "Choose an option (1/2/3): " choice

            case $choice in
                1)
                    # Only retry alias creation, not the whole flow
                    local alias_retry=0
                    local max_alias_retries=3
                    local alias_success=false

                    while [ $alias_retry -lt $max_alias_retries ] && [ "$alias_success" == "false" ]; do
                        alias_retry=$((alias_retry + 1))
                        echo -e "${YELLOW}Retrying alias creation... (Attempt $alias_retry of $max_alias_retries)${NC}"

                        FLOW_ALIAS_RESPONSE=$(aws bedrock-agent create-flow-alias \
                            --flow-identifier $FLOW_ID \
                            --name "Production" \
                            --routing-configuration file://routing_config.json \
                            --region $REGION)

                        if [ $? -eq 0 ]; then
                            alias_success=true
                            break
                        fi

                        sleep 5
                    done

                    if [ "$alias_success" == "false" ]; then
                        echo -e "${RED}Maximum alias creation retries reached. Continuing without alias.${NC}"
                        rm -f flow_definition.json routing_config.json
                        echo "FLOW_ID=$FLOW_ID" > flow_info.txt
                        echo "FLOW_VERSION=$FLOW_VERSION" >> flow_info.txt
                        echo -e "${GREEN}Flow created with ID: $FLOW_ID (but without alias)${NC}"
                        return 0
                    fi
                    ;;
                2)
                    echo -e "${YELLOW}Continuing without flow alias.${NC}"
                    rm -f flow_definition.json routing_config.json
                    echo "FLOW_ID=$FLOW_ID" > flow_info.txt
                    echo "FLOW_VERSION=$FLOW_VERSION" >> flow_info.txt
                    echo -e "${GREEN}Flow created with ID: $FLOW_ID (but without alias)${NC}"
                    return 0
                    ;;
                3)
                    echo -e "${RED}Flow creation cancelled.${NC}"
                    rm -f flow_definition.json routing_config.json
                    return 1
                    ;;
            esac
        }

        # Extract flow alias ID
        FLOW_ALIAS_ID=$(echo $FLOW_ALIAS_RESPONSE | jq -r '.id')

        if [ -z "$FLOW_ALIAS_ID" ] || [ "$FLOW_ALIAS_ID" == "null" ]; then
            echo -e "${RED}Failed to extract flow alias ID.${NC}"

            echo -e "${BLUE}Options:${NC}"
            echo -e "1. Continue without alias information"
            echo -e "2. Cancel flow creation"

            read -p "Choose an option (1/2): " choice

            case $choice in
                1)
                    echo -e "${YELLOW}Continuing without flow alias information.${NC}"
                    rm -f flow_definition.json routing_config.json
                    echo "FLOW_ID=$FLOW_ID" > flow_info.txt
                    echo "FLOW_VERSION=$FLOW_VERSION" >> flow_info.txt
                    echo -e "${GREEN}Flow created with ID: $FLOW_ID (but alias ID couldn't be extracted)${NC}"
                    return 0
                    ;;
                *)
                    echo -e "${RED}Flow creation cancelled.${NC}"
                    rm -f flow_definition.json routing_config.json
                    return 1
                    ;;
            esac
        }

        echo -e "${GREEN}Created flow alias with ID: $FLOW_ALIAS_ID${NC}"

        # Save flow information to file
        echo "FLOW_ID=$FLOW_ID" > flow_info.txt
        echo "FLOW_ALIAS_ID=$FLOW_ALIAS_ID" >> flow_info.txt
        echo "FLOW_VERSION=$FLOW_VERSION" >> flow_info.txt

        echo -e "${GREEN}Flow created and configured successfully.${NC}"

        # Clean up
        rm -f flow_definition.json routing_config.json

        # We've successfully created the flow, so exit the retry loop
        break
    }

    if [ $retry_count -ge $max_retries ]; then
        echo -e "${RED}Maximum retries reached for flow creation.${NC}"
        return 1
    fi

    return 0
}

# Function to create all resources
create_resources() {
    check_dependencies
    create_iam_role
    create_s3_bucket
    upload_prompts
    create_agents
    create_flow

    echo -e "${GREEN}All resources created successfully.${NC}"
    echo -e "${BLUE}Your Storybook processing flow is ready to use.${NC}"
    echo -e "${BLUE}Flow ID: $FLOW_ID${NC}"
    echo -e "${BLUE}Flow Alias: Production (ID: $FLOW_ALIAS_ID)${NC}"
    echo -e "${BLUE}S3 Bucket: $FLOW_BUCKET_NAME${NC}"
}

# Function to modify resources
modify_resources() {
    echo -e "${YELLOW}Modifying existing resources is not fully implemented.${NC}"
    echo -e "${YELLOW}For significant changes, it's recommended to delete and recreate the flow.${NC}"

    # Here you would include logic to modify specific aspects of the flow
    # This would require loading existing IDs from saved files

    echo -e "${BLUE}Options for modification:${NC}"
    echo -e "1. Update agent prompts"
    echo -e "2. Modify flow definition"
    echo -e "3. Return to main menu"

    read -p "Choose an option: " modify_option

    case $modify_option in
        1)
            echo -e "${BLUE}Updating agent prompts...${NC}"
            # Logic to update prompts would go here
            ;;
        2)
            echo -e "${BLUE}Modifying flow definition...${NC}"
            # Logic to modify flow would go here
            ;;
        3)
            return
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            ;;
    esac
}

# Function to delete all resources
delete_resources() {
    echo -e "${RED}WARNING: This will delete all resources created for the Storybook processing flow.${NC}"
    read -p "Are you sure you want to proceed? (y/n): " confirm

    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo -e "${BLUE}Deletion cancelled.${NC}"
        return
    fi

    # Load resource IDs if available
    if [ -f flow_info.txt ]; then
        source flow_info.txt
    else
        read -p "Flow ID: " FLOW_ID
        read -p "Flow Alias ID: " FLOW_ALIAS_ID
    fi

    if [ -f agent_ids.txt ]; then
        source agent_ids.txt
    fi

    echo -e "${BLUE}Deleting flow...${NC}"
    # Delete flow alias first
    if [ ! -z "$FLOW_ALIAS_ID" ] && [ ! -z "$FLOW_ID" ]; then
        # Updated to use alias-identifier instead of flow-alias-id
        debug_aws_command "aws bedrock-agent delete-flow-alias --flow-identifier $FLOW_ID --alias-identifier $FLOW_ALIAS_ID --region $REGION"
        aws bedrock-agent delete-flow-alias \
            --flow-identifier $FLOW_ID \
            --alias-identifier $FLOW_ALIAS_ID \
            --region $REGION 2>/dev/null || true

        # Delete flow
        debug_aws_command "aws bedrock-agent delete-flow --flow-identifier $FLOW_ID --region $REGION"
        aws bedrock-agent delete-flow \
            --flow-identifier $FLOW_ID \
            --region $REGION 2>/dev/null || true
    fi

    echo -e "${BLUE}Deleting agents...${NC}"
    # Delete all agents if agent_ids.txt exists
    if [ -n "${AGENT_IDS[*]}" ]; then
        for agent_name in "${!AGENT_IDS[@]}"; do
            agent_id=${AGENT_IDS[$agent_name]}
            echo -e "Deleting agent: $agent_name ($agent_id)"

            # Delete agent alias
            debug_aws_command "aws bedrock-agent delete-agent-alias --agent-id $agent_id --agent-alias-id Production --region $REGION"
            aws bedrock-agent delete-agent-alias \
                --agent-id $agent_id \
                --agent-alias-id Production \
                --region $REGION 2>/dev/null || true

            # Delete agent
            debug_aws_command "aws bedrock-agent delete-agent --agent-id $agent_id --skip-resource-in-use-check --region $REGION"
            aws bedrock-agent delete-agent \
                --agent-id $agent_id \
                --skip-resource-in-use-check \
                --region $REGION 2>/dev/null || true
        done
    fi

    echo -e "${BLUE}Deleting S3 bucket...${NC}"
    # Delete S3 bucket
    if [ ! -z "$FLOW_BUCKET_NAME" ]; then
        debug_aws_command "aws s3 rm s3://${FLOW_BUCKET_NAME} --recursive --region $REGION"
        aws s3 rm s3://${FLOW_BUCKET_NAME} --recursive --region $REGION 2>/dev/null || true

        debug_aws_command "aws s3 rb s3://${FLOW_BUCKET_NAME} --force --region $REGION"
        aws s3 rb s3://${FLOW_BUCKET_NAME} --force --region $REGION 2>/dev/null || true
    fi

    echo -e "${BLUE}Deleting IAM role...${NC}"
    # Delete IAM role
    if [ ! -z "$ROLE_NAME" ]; then
        debug_aws_command "aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/StorybookPolicy"
        aws iam detach-role-policy \
            --role-name $ROLE_NAME \
            --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/StorybookPolicy 2>/dev/null || true

        debug_aws_command "aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/StorybookPolicy"
        aws iam delete-policy \
            --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/StorybookPolicy 2>/dev/null || true

        debug_aws_command "aws iam delete-role --role-name $ROLE_NAME"
        aws iam delete-role \
            --role-name $ROLE_NAME 2>/dev/null || true
    fi

    # Remove info files
    rm -f flow_info.txt agent_ids.txt

    echo -e "${GREEN}All resources deleted successfully.${NC}"
}

# Function to display information about a deployed flow
show_info() {
    echo -e "${BLUE}Retrieving information about deployed resources...${NC}"

    if [ -f flow_info.txt ]; then
        source flow_info.txt
        echo -e "${GREEN}Flow Information:${NC}"
        echo -e "Flow ID: $FLOW_ID"
        echo -e "Flow Alias ID: $FLOW_ALIAS_ID"

        # Get flow details
        debug_aws_command "aws bedrock-agent get-flow --flow-identifier $FLOW_ID --region $REGION | jq '.name, .description, .status'"
        aws bedrock-agent get-flow \
            --flow-identifier $FLOW_ID \
            --region $REGION | jq '.name, .description, .status' 2>/dev/null || echo -e "${YELLOW}Flow details cannot be retrieved. The flow may have been deleted.${NC}"
    else
        echo -e "${YELLOW}Flow information not found. Has a flow been deployed?${NC}"
    fi

    if [ -f agent_ids.txt ]; then
        source agent_ids.txt
        echo -e "${GREEN}Agent Information:${NC}"
        for agent_name in "${!AGENT_IDS[@]}"; do
            agent_id=${AGENT_IDS[$agent_name]}
            echo -e "$agent_name: $agent_id"
        done
    else
        echo -e "${YELLOW}Agent information not found. Have agents been deployed?${NC}"
    fi

    echo -e "${GREEN}S3 Bucket: $FLOW_BUCKET_NAME${NC}"
}

# Function to poll for flow execution status
wait_for_flow_execution() {
    local flow_id=$1
    local execution_id=$2
    local max_attempts=60  # 30 minutes at 30-second intervals
    local delay=30
    local attempt=0

    # Check if flow ID is valid
    if [ -z "$flow_id" ] || [ "$flow_id" == "null" ]; then
        echo -e "${RED}Invalid flow ID provided to wait_for_flow_execution. Cannot proceed.${NC}"
        return 1
    fi

    # Check if execution ID is valid
    if [ -z "$execution_id" ] || [ "$execution_id" == "null" ]; then
        echo -e "${RED}Invalid execution ID provided to wait_for_flow_execution. Cannot proceed.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Waiting for flow execution to complete...${NC}"

    while ((attempt < max_attempts)); do
        debug_aws_command "aws bedrock-agent-runtime get-flow-execution --flow-identifier $flow_id --execution-id $execution_id --region $REGION"
        GET_RESPONSE=$(aws bedrock-agent-runtime get-flow-execution \
            --flow-identifier $flow_id \
            --execution-id $execution_id \
            --region $REGION 2>/dev/null)

        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}Error getting flow execution status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        STATUS=$(echo $GET_RESPONSE | jq -r '.status' 2>/dev/null)

        if [ -z "$STATUS" ] || [ "$STATUS" == "null" ]; then
            echo -e "${YELLOW}Could not extract flow execution status. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
            sleep $delay
            attempt=$((attempt+1))
            continue
        fi

        if [[ "$STATUS" == "COMPLETED" || "$STATUS" == "FAILED" || "$STATUS" == "STOPPED" ]]; then
            echo -e "${GREEN}Flow execution completed with status: $STATUS${NC}"
            return 0
        fi

        echo -e "${YELLOW}Flow execution status: $STATUS. Waiting $delay seconds before retry (attempt $((attempt+1))/$max_attempts)${NC}"
        sleep $delay
        attempt=$((attempt+1))
    done

    echo -e "${RED}Timed out waiting for flow execution to complete. Last status: $STATUS${NC}"
    return 1
}

# Function to test the flow with a sample Storybook
test_flow() {
    echo -e "${BLUE}Testing the Storybook processing flow...${NC}"

    if [ ! -f flow_info.txt ]; then
        echo -e "${RED}Flow information not found. Please deploy the flow first.${NC}"
        return
    fi

    source flow_info.txt

    # Verify flow ID
    if [ -z "$FLOW_ID" ] || [ "$FLOW_ID" == "null" ]; then
        echo -e "${RED}Invalid flow ID found in flow_info.txt. Please redeploy the flow.${NC}"
        return 1
    fi

    # Create a small test Storybook
    cat > test_storybook.json << EOF
{
  "document": "TITLE: The Test Storybook\n\nChapter 1: The Beginning\n\nIt was a dark and stormy night. The protagonist couldn't sleep, tossing and turning as the rain beat against the window. Tomorrow would bring new challenges, but for now, the quiet of the night was both comforting and unsettling.\n\nChapter 2: The Discovery\n\nThe morning brought unexpected news. What seemed like an ordinary day would soon reveal secrets that had been buried for decades."
}
EOF

    echo -e "${BLUE}Invoking flow with test Storybook...${NC}"

    # Invoke the flow
    debug_aws_command "aws bedrock-agent-runtime invoke-flow --flow-identifier $FLOW_ID --flow-alias \"Production\" --inputs file://test_storybook.json --region $REGION"
    INVOKE_RESPONSE=$(aws bedrock-agent-runtime invoke-flow \
        --flow-identifier $FLOW_ID \
        --flow-alias "Production" \
        --inputs file://test_storybook.json \
        --region $REGION)

    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to invoke flow. Please check your flow configuration.${NC}"
        rm -f test_storybook.json
        return 1
    fi

    # Extract execution ID
    EXECUTION_ID=$(echo $INVOKE_RESPONSE | jq -r '.executionId')

    if [ -z "$EXECUTION_ID" ] || [ "$EXECUTION_ID" == "null" ]; then
        echo -e "${RED}Failed to extract execution ID. Cannot monitor execution.${NC}"
        rm -f test_storybook.json
        return 1
    fi

    echo -e "${GREEN}Flow execution started with ID: $EXECUTION_ID${NC}"
    echo -e "${YELLOW}This may take several minutes to complete...${NC}"

    # Wait for flow to complete using custom polling function
    wait_for_flow_execution $FLOW_ID $EXECUTION_ID

    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to monitor flow execution. Please check manually.${NC}"
        rm -f test_storybook.json
        return 1
    fi

    echo -e "${GREEN}Flow execution completed with status: $STATUS${NC}"

    # Get execution results
    debug_aws_command "aws bedrock-agent-runtime get-flow-execution --flow-identifier $FLOW_ID --execution-id $EXECUTION_ID --region $REGION"
    RESULT=$(aws bedrock-agent-runtime get-flow-execution \
        --flow-identifier $FLOW_ID \
        --execution-id $EXECUTION_ID \
        --region $REGION)

    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to retrieve flow execution results.${NC}"
        rm -f test_storybook.json
        return 1
    fi

    # Extract outputs
    echo $RESULT | jq -r '.outputs.document' > polished_storybook.txt 2>/dev/null || echo "No document output generated" > polished_storybook.txt
    echo $RESULT | jq -r '.outputs.executiveSummary' > executive_summary.txt 2>/dev/null || echo "No executive summary generated" > executive_summary.txt
    echo $RESULT | jq -r '.outputs.creativeVision' > creative_vision.txt 2>/dev/null || echo "No creative vision generated" > creative_vision.txt
    echo $RESULT | jq -r '.outputs.marketAnalysis' > market_analysis.txt 2>/dev/null || echo "No market analysis generated" > market_analysis.txt

    echo -e "${GREEN}Test completed. Results saved to:${NC}"
    echo -e "${GREEN}- polished_storybook.txt${NC}"
    echo -e "${GREEN}- executive_summary.txt${NC}"
    echo -e "${GREEN}- creative_vision.txt${NC}"
    echo -e "${GREEN}- market_analysis.txt${NC}"

    # Clean up
    rm -f test_storybook.json
}

# Main menu function
main_menu() {
    while true; do
        echo -e "\n${BLUE}=== AWS Bedrock Flow Hierarchical Multi-Agent Deployment ====${NC}"
        echo -e "1. Create Storybook processing flow"
        echo -e "2. Modify existing flow"
        echo -e "3. Delete all resources"
        echo -e "4. Show information about deployed resources"
        echo -e "5. Test flow with sample Storybook"
        echo -e "6. Exit"

        read -p "Choose an option: " option

        case $option in
            1)
                create_resources
                ;;
            2)
                modify_resources
                ;;
            3)
                delete_resources
                ;;
            4)
                show_info
                ;;
            5)
                test_flow
                ;;
            6)
                echo -e "${GREEN}Exiting. Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                ;;
        esac
    done
}

# Script start
echo -e "${BLUE}AWS Bedrock Flow Hierarchical Multi-Agent Deployment Script${NC}"
echo -e "${BLUE}This script will help you deploy a complex multi-agent workflow for Storybook processing${NC}"
main_menu
