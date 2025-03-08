#!/bin/bash

# Configuration variables
REGION="us-east-1"
FLOW_NAME="ManuscriptRefinementFlow"
FLOW_DESCRIPTION="Hierarchical multi-agent workflow for manuscript refinement"
FLOW_DEFINITION_FILE="manuscript_flow_definition.json"
S3_BUCKET=""
S3_PREFIX="bedrock-flows"
IAM_ROLE_ARN=""
MODEL_ID="anthropic.claude-3-sonnet-20240229-v1:0"

# Arrays to store agent definitions by tier
declare -A EXECUTIVE_TIER
declare -A STRUCTURAL_TIER
declare -A CONTENT_TIER
declare -A EDITORIAL_TIER
declare -A MARKET_TIER

# Function to check AWS CLI version
check_aws_cli() {
    echo "Checking AWS CLI version..."
    if ! command -v aws &> /dev/null; then
        echo "Error: AWS CLI is not installed."
        exit 1
    fi
    
    version=\$(aws --version | cut -d' ' -f1 | cut -d'/' -f2)
    major=\$(echo \$version | cut -d'.' -f1)
    minor=\$(echo \$version | cut -d'.' -f2)
    
    if [ "\$major" -lt 2 ] || ([ "\$major" -eq 2 ] && [ "\$minor" -lt 24 ]); then
        echo "Error: AWS CLI version 2.24 or higher required. Current version: \$version"
        exit 1
    fi
    echo "AWS CLI version check passed: \$version"
}

# Function to validate S3 bucket
validate_s3_bucket() {
    echo "Validating S3 bucket access..."
    if aws s3api head-bucket --bucket "\$S3_BUCKET" 2>/dev/null; then
        echo "S3 bucket validation successful."
    else
        echo "Creating S3 bucket \$S3_BUCKET..."
        if aws s3api create-bucket --bucket "\$S3_BUCKET" --region "\$REGION"; then
            echo "S3 bucket created successfully."
        else
            echo "Error: Failed to create S3 bucket."
            return 1
        fi
    fi
    return 0
}

# Function to initialize agent prompts
initialize_agent_prompts() {
    echo "Initializing agent prompts..."
    
    # Executive Tier
    EXECUTIVE_TIER["ExecutiveDirector"]="You are the Executive Director responsible for overseeing the entire manuscript refinement process. As the system orchestrator and final decision-maker, your tasks include: 1) Maintain global vision of manuscript goals, 2) Give final approval on major revisions, 3) Interface between system and human author, 4) Coordinate all other agents in the workflow. Analyze the manuscript holistically, identify its core strengths and weaknesses, and provide high-level guidance for improvement while maintaining the author's vision."
    
    EXECUTIVE_TIER["CreativeDirector"]="You are the Creative Director responsible for guarding the artistic vision of the manuscript. Your tasks include: 1) Define and protect core creative elements, 2) Balance commercial considerations with artistic integrity, 3) Guide stylistic decisions, 4) Ensure the manuscript maintains a distinctive voice. Analyze the manuscript with focus on its creative merits, unique qualities, and artistic potential."
    
    EXECUTIVE_TIER["HumanFeedbackManager"]="You are the Human Feedback Manager responsible for interpreting author intentions and external feedback. Your tasks include: 1) Translate author preferences into system parameters, 2) Collect and interpret beta reader/editor feedback, 3) Identify areas where human guidance is needed, 4) Ensure revisions align with the author's vision. Review the manuscript and identify areas where further human input would be valuable."
    
    EXECUTIVE_TIER["QualityAssessmentDirector"]="You are the Quality Assessment Director responsible for objectively evaluating manuscript progression. Your tasks include: 1) Establish quality metrics for the project, 2) Conduct quality audits, 3) Identify regression in manuscript quality, 4) Certify when quality standards are met. Evaluate the manuscript against quality benchmarks and provide specific recommendations for improvement."
    
    EXECUTIVE_TIER["ProjectTimelineManager"]="You are the Project Timeline Manager responsible for process efficiency. Your tasks include: 1) Create and maintain revision schedules, 2) Identify workflow bottlenecks, 3) Adjust resource allocation based on priorities, 4) Track progress against milestones. Analyze the manuscript's current state and provide recommendations for prioritizing revision work."
    
    EXECUTIVE_TIER["MarketAlignmentDirector"]="You are the Market Alignment Director responsible for commercial viability. Your tasks include: 1) Analyze market trends relevant to the manuscript, 2) Identify commercial opportunities and risks, 3) Guide positioning strategy, 4) Ensure marketability of the final product. Evaluate the manuscript's market potential and provide recommendations to enhance its commercial appeal."
    
    # Structural Tier
    STRUCTURAL_TIER["StructureArchitect"]="You are the Structure Architect responsible for the manuscript's narrative architecture. Your tasks include: 1) Analyze and optimize overall narrative structure, 2) Balance act/scene distribution, 3) Identify structural weaknesses, 4) Recommend major restructuring when needed. Evaluate the manuscript's structure and provide specific recommendations for structural improvements."
    
    STRUCTURAL_TIER["PlotDevelopmentSpecialist"]="You are the Plot Development Specialist responsible for narrative progression. Your tasks include: 1) Analyze cause-effect relationships, 2) Improve conflict development, 3) Enhance plot twists and revelations, 4) Ensure logical plot progression. Analyze the plot for cohesion, engagement, and logical progression, providing specific recommendations for improvement."
    
    # Add more agents for each tier...
    
    # Content Development Tier
    CONTENT_TIER["ContentDevelopmentDirector"]="You are the Content Development Director responsible for managing content creation processes. Your tasks include: 1) Coordinate content development activities, 2) Identify content gaps and opportunities, 3) Balance content density and pacing, 4) Guide scene prioritization. Analyze the manuscript's content for completeness, balance, and engagement."
    
    # Editorial Tier
    EDITORIAL_TIER["EditorialDirector"]="You are the Editorial Director responsible for overseeing all refinement. Your tasks include: 1) Coordinate all editorial activities, 2) Balance different editing priorities, 3) Guide editorial approach, 4) Ensure editorial quality. Provide comprehensive editorial guidance for the manuscript."
    
    # Market Positioning Tier
    MARKET_TIER["PositioningSpecialist"]="You are the Positioning Specialist responsible for market placement strategy. Your tasks include: 1) Identify optimal genre positioning, 2) Analyze competitive landscape, 3) Define unique selling proposition, 4) Guide market-focused revisions. Evaluate the manuscript's positioning in the current market and provide recommendations to enhance its competitiveness."
    
    echo "Agent prompts initialized."
}

# Function to create Lambda for text splitting
create_text_splitter_lambda() {
    echo "Creating text splitter Lambda function..."
    
    # Create a temporary directory for Lambda code
    mkdir -p lambda_code
    
    # Create Python script for text splitting
    cat > lambda_code/text_splitter.py << 'EOF'
import json
import re

def lambda_handler(event, context):
    """Split large manuscript into manageable chunks."""
    manuscript = event.get('manuscript', '')
    title = event.get('title', '')
    
    # Calculate manuscript size
    manuscript_size = len(manuscript)
    
    # If manuscript is small enough, return it as a single chunk
    if manuscript_size < 100000:  # ~25,000 tokens
        return {
            'chunks': [{'text': manuscript, 'index': 0, 'total': 1}],
            'title': title,
            'total_chunks': 1
        }
    
    # Split by chapters or logical sections if possible
    chapter_pattern = r'(?i)^(chapter|section|\d+\.)\s+\w+'
    chapters = re.split(chapter_pattern, manuscript, flags=re.MULTILINE)
    
    # If no clear chapter divisions or too few, split by paragraphs
    if len(chapters) < 3:
        paragraphs = re.split(r'\n\s*\n', manuscript)
        chunks = []
        current_chunk = ""
        chunk_index = 0
        
        for para in paragraphs:
            if len(current_chunk) + len(para) > 80000:  # ~20,000 tokens
                if current_chunk:
                    chunks.append(current_chunk)
                    current_chunk = para
                else:
                    chunks.append(para)
            else:
                current_chunk += "\n\n" + para if current_chunk else para
        
        if current_chunk:
            chunks.append(current_chunk)
    else:
        chunks = chapters
    
    # Format chunks with metadata
    result_chunks = []
    total_chunks = len(chunks)
    
    for i, chunk in enumerate(chunks):
        if chunk.strip():  # Skip empty chunks
            result_chunks.append({
                'text': chunk,
                'index': i,
                'total': total_chunks
            })
    
    return {
        'chunks': result_chunks,
        'title': title,
        'total_chunks': len(result_chunks)
    }
EOF

    # Create Lambda deployment package
    cd lambda_code
    zip -r ../text_splitter.zip text_splitter.py
    cd ..
    
    # Create Lambda function
    LAMBDA_NAME="manuscript-text-splitter"
    aws lambda create-function \
        --function-name \$LAMBDA_NAME \
        --runtime python3.9 \
        --handler text_splitter.lambda_handler \
        --zip-file fileb://text_splitter.zip \
        --role \$IAM_ROLE_ARN \
        --region \$REGION
    
    # Get Lambda ARN
    TEXT_SPLITTER_ARN=\$(aws lambda get-function \
        --function-name \$LAMBDA_NAME \
        --query 'Configuration.FunctionArn' \
        --output text \
        --region \$REGION)
    
    # Clean up
    rm -rf lambda_code
    rm text_splitter.zip
    
    echo "Text splitter Lambda created with ARN: \$TEXT_SPLITTER_ARN"
}

# Function to create Lambda for text merging
create_text_merger_lambda() {
    echo "Creating text merger Lambda function..."
    
    # Create a temporary directory for Lambda code
    mkdir -p lambda_code
    
    # Create Python script for text merging
    cat > lambda_code/text_merger.py << 'EOF'
import json

def lambda_handler(event, context):
    """Merge processed manuscript chunks back together."""
    # Extract results from all agents
    results = event.get('results', [])
    
    # Extract manuscript chunks and sort by index
    manuscript_chunks = []
    for result in results:
        if isinstance(result, dict) and 'chunks' in result:
            for chunk in result.get('chunks', []):
                manuscript_chunks.append(chunk)
    
    # Sort chunks by index
    manuscript_chunks.sort(key=lambda x: x.get('index', 0))
    
    # Merge chunks
    final_manuscript = ""
    for chunk in manuscript_chunks:
        text = chunk.get('processed_text', chunk.get('text', ''))
        final_manuscript += text + "\n\n"
    
    return {
        'mergedResult': final_manuscript.strip()
    }
EOF

    # Create Lambda deployment package
    cd lambda_code
    zip -r ../text_merger.zip text_merger.py
    cd ..
    
    # Create Lambda function
    LAMBDA_NAME="manuscript-text-merger"
    aws lambda create-function \
        --function-name \$LAMBDA_NAME \
        --runtime python3.9 \
        --handler text_merger.lambda_handler \
        --zip-file fileb://text_merger.zip \
        --role \$IAM_ROLE_ARN \
        --region \$REGION
    
    # Get Lambda ARN
    TEXT_MERGER_ARN=\$(aws lambda get-function \
        --function-name \$LAMBDA_NAME \
        --query 'Configuration.FunctionArn' \
        --output text \
        --region \$REGION)
    
    # Clean up
    rm -rf lambda_code
    rm text_merger.zip
    
    echo "Text merger Lambda created with ARN: \$TEXT_MERGER_ARN"
}

# Function to generate flow definition
generate_flow_definition() {
    echo "Generating flow definition..."
    
    # Create base JSON structure
    cat > \$FLOW_DEFINITION_FILE << EOF
{
  "name": "\$FLOW_NAME",
  "description": "\$FLOW_DESCRIPTION",
  "nodes": [
    {
      "name": "InputNode",
      "type": "Input",
      "configuration": {
        "inputSchema": {
          "title": { "type": "string" },
          "manuscript": { "type": "string" }
        }
      }
    },
    {
      "name": "TextSplitterNode",
      "type": "LambdaFunctionNode",
      "configuration": {
        "lambdaArn": "\$TEXT_SPLITTER_ARN",
        "inputMappings": {
          "manuscript": "{{InputNode.manuscript}}",
          "title": "{{InputNode.title}}"
        }
      }
    },
EOF

    # Add agent nodes for Executive Tier
    echo "Adding Executive Tier agents to flow definition..."
    for agent_name in "\${!EXECUTIVE_TIER[@]}"; do
        cat >> \$FLOW_DEFINITION_FILE << EOF
    {
      "name": "\${agent_name}Node",
      "type": "PromptNode",
      "configuration": {
        "modelId": "\$MODEL_ID",
        "prompt": "{{TextSplitterNode.chunks}} represents sections of a manuscript with title {{TextSplitterNode.title}}. As \${agent_name}, \${EXECUTIVE_TIER[\$agent_name]} Analyze this section and provide specific feedback and improvements. Your output should maintain the format provided.",
        "inputMappings": {
          "input": "{{TextSplitterNode.chunks}}"
        }
      }
    },
EOF
    done

    # Add agent nodes for Structural Tier
    echo "Adding Structural Tier agents to flow definition..."
    for agent_name in "\${!STRUCTURAL_TIER[@]}"; do
        cat >> \$FLOW_DEFINITION_FILE << EOF
    {
      "name": "\${agent_name}Node",
      "type": "PromptNode",
      "configuration": {
        "modelId": "\$MODEL_ID",
        "prompt": "{{TextSplitterNode.chunks}} represents sections of a manuscript with title {{TextSplitterNode.title}}. As \${agent_name}, \${STRUCTURAL_TIER[\$agent_name]} Review the executive team's feedback and build upon it with your specialized structural analysis.",
        "inputMappings": {
          "input": "{{ExecutiveDirectorNode.output}}"
        }
      }
    },
EOF
    done

    # Add agent nodes for Content Tier
    echo "Adding Content Tier agents to flow definition..."
    for agent_name in "\${!CONTENT_TIER[@]}"; do
        cat >> \$FLOW_DEFINITION_FILE << EOF
    {
      "name": "\${agent_name}Node",
      "type": "PromptNode",
      "configuration": {
        "modelId": "\$MODEL_ID",
        "prompt": "{{TextSplitterNode.chunks}} represents sections of a manuscript with title {{TextSplitterNode.title}}. As \${agent_name}, \${CONTENT_TIER[\$agent_name]} Review the structural team's feedback and enhance the content accordingly.",
        "inputMappings": {
          "input": "{{StructureArchitectNode.output}}"
        }
      }
    },
EOF
    done

    # Add agent nodes for Editorial Tier
    echo "Adding Editorial Tier agents to flow definition..."
    for agent_name in "\${!EDITORIAL_TIER[@]}"; do
        cat >> \$FLOW_DEFINITION_FILE << EOF
    {
      "name": "\${agent_name}Node",
      "type": "PromptNode",
      "configuration": {
        "modelId": "\$MODEL_ID",
        "prompt": "{{TextSplitterNode.chunks}} represents sections of a manuscript with title {{TextSplitterNode.title}}. As \${agent_name}, \${EDITORIAL_TIER[\$agent_name]} Review the content team's work and provide editorial refinement.",
        "inputMappings": {
          "input": "{{ContentDevelopmentDirectorNode.output}}"
        }
      }
    },
EOF
    done

    # Add agent nodes for Market Tier
    echo "Adding Market Tier agents to flow definition..."
    for agent_name in "\${!MARKET_TIER[@]}"; do
        cat >> \$FLOW_DEFINITION_FILE << EOF
    {
      "name": "\${agent_name}Node",
      "type": "PromptNode",
      "configuration": {
        "modelId": "\$MODEL_ID",
        "prompt": "{{TextSplitterNode.chunks}} represents sections of a manuscript with title {{TextSplitterNode.title}}. As \${agent_name}, \${MARKET_TIER[\$agent_name]} Review the editorial team's refinements and enhance market positioning.",
        "inputMappings": {
          "input": "{{EditorialDirectorNode.output}}"
        }
      }
    },
EOF
    done

    # Add text merger node
    cat >> \$FLOW_DEFINITION_FILE << EOF
    {
      "name": "TextMergerNode",
      "type": "LambdaFunctionNode",
      "configuration": {
        "lambdaArn": "\$TEXT_MERGER_ARN",
        "inputMappings": {
          "results": [
            "{{PositioningSpecialistNode.output}}"
          ]
        }
      }
    },
    {
      "name": "FinalReviewNode",
      "type": "PromptNode",
      "configuration": {
        "modelId": "\$MODEL_ID",
        "prompt": "As Executive Director, review this complete refined manuscript and ensure it maintains coherence, quality, and alignment with the original vision. Make final adjustments as needed.",
        "inputMappings": {
          "input": "{{TextMergerNode.mergedResult}}"
        }
      }
    },
    {
      "name": "OutputNode",
      "type": "Output",
      "configuration": {
        "outputSchema": {
          "refinedManuscript": { "type": "string" }
        },
        "outputMappings": {
          "refinedManuscript": "{{FinalReviewNode.output}}"
        }
      }
    }
  ],
  "edges": [
    {"from": "InputNode", "to": "TextSplitterNode"},
EOF

    # Add edges for Executive Tier
    for agent_name in "\${!EXECUTIVE_TIER[@]}"; do
        cat >> \$FLOW_DEFINITION_FILE << EOF
    {"from": "TextSplitterNode", "to": "\${agent_name}Node"},
EOF
    done

    # Add edges between tiers
    cat >> \$FLOW_DEFINITION_FILE << EOF
    {"from": "ExecutiveDirectorNode", "to": "StructureArchitectNode"},
    {"from": "StructureArchitectNode", "to": "ContentDevelopmentDirectorNode"},
    {"from": "ContentDevelopmentDirectorNode", "to": "EditorialDirectorNode"},
    {"from": "EditorialDirectorNode", "to": "PositioningSpecialistNode"},
    {"from": "PositioningSpecialistNode", "to": "TextMergerNode"},
    {"from": "TextMergerNode", "to": "FinalReviewNode"},
    {"from": "FinalReviewNode", "to": "OutputNode"}
  ]
}
EOF

    echo "Flow definition generated: \$FLOW_DEFINITION_FILE"
}

# Function to create flow
create_flow() {
    echo "Creating flow in Amazon Bedrock..."
    
    # Upload flow definition to S3
    aws s3 cp "\$FLOW_DEFINITION_FILE" "s3://\$S3_BUCKET/\$S3_PREFIX/\$FLOW_DEFINITION_FILE" \
        --region "\$REGION"
    
    # Create flow
    FLOW_ID=\$(aws bedrock create-flow \
        --flow-name "\$FLOW_NAME" \
        --definition-s3-location "Bucket=\$S3_BUCKET,Key=\$S3_PREFIX/\$FLOW_DEFINITION_FILE" \
        --execution-role-arn "\$IAM_ROLE_ARN" \
        --region "\$REGION" \
        --query "flowId" \
        --output text)
    
    if [ -n "\$FLOW_ID" ]; then
        echo "Flow created successfully with ID: \$FLOW_ID"
        
        # Prepare flow for use
        aws bedrock prepare-flow \
            --flow-id "\$FLOW_ID" \
            --region "\$REGION"
        
        echo "Flow preparation initiated. Check AWS console for preparation status."
    else
        echo "Error: Failed to create flow."
    fi
}

# Function to delete flow
delete_flow() {
    echo "Finding existing flows..."
    
    # List flows and find flow ID
    FLOW_ID=\$(aws bedrock list-flows \
        --filters "name=flowName,operator=EQUALS,values=\$FLOW_NAME" \
        --region "\$REGION" \
        --query "flowSummaries[0].flowId" \
        --output text)
    
    if [ "\$FLOW_ID" != "None" ] && [ -n "\$FLOW_ID" ]; then
        echo "Deleting flow with ID: \$FLOW_ID"
        
        aws bedrock delete-flow \
            --flow-id "\$FLOW_ID" \
            --region "\$REGION"
        
        echo "Flow deleted successfully."
    else
        echo "No flow found with name: \$FLOW_NAME"
    fi
    
    # Delete Lambda functions
    echo "Checking for Lambda functions to delete..."
    
    for LAMBDA_NAME in "manuscript-text-splitter" "manuscript-text-merger"; do
        if aws lambda get-function --function-name "\$LAMBDA_NAME" --region "\$REGION" &> /dev/null; then
            echo "Deleting Lambda function: \$LAMBDA_NAME"
            aws lambda delete-function --function-name "\$LAMBDA_NAME" --region "\$REGION"
        fi
    done
}

# Function to update flow
update_flow() {
    echo "Updating flow..."
    
    # Find flow ID
    FLOW_ID=\$(aws bedrock list-flows \
        --filters "name=flowName,operator=EQUALS,values=\$FLOW_NAME" \
        --region "\$REGION" \
        --query "flowSummaries[0].flowId" \
        --output text)
    
    if [ "\$FLOW_ID" != "None" ] && [ -n "\$FLOW_ID" ]; then
        # Regenerate flow definition
        generate_flow_definition
        
        # Upload updated flow definition to S3
        aws s3 cp "\$FLOW_DEFINITION_FILE" "s3://\$S3_BUCKET/\$S3_PREFIX/\$FLOW_DEFINITION_FILE" \
            --region "\$REGION"
        
        # Update flow
        aws bedrock update-flow \
            --flow-id "\$FLOW_ID" \
            --definition-s3-location "Bucket=\$S3_BUCKET,Key=\$S3_PREFIX/\$FLOW_DEFINITION_FILE" \
            --region "\$REGION"
        
        # Prepare updated flow
        aws bedrock prepare-flow \
            --flow-id "\$FLOW_ID" \
            --region "\$REGION"
        
        echo "Flow updated successfully. Check AWS console for preparation status."
    else
        echo "No flow found with name: \$FLOW_NAME"
    fi
}

# Function for deployment setup
setup_deployment() {
    echo "Setting up deployment configuration..."
    
    read -p "Enter AWS Region [\$REGION]: " input_region
    REGION=\${input_region:-\$REGION}
    
    read -p "Enter S3 Bucket for flow definition storage: " S3_BUCKET
    while [ -z "\$S3_BUCKET" ]; do
        echo "S3 Bucket name is required."
        read -p "Enter S3 Bucket for flow definition storage: " S3_BUCKET
    done
    
    read -p "Enter IAM Role ARN for service execution: " IAM_ROLE_ARN
    while [ -z "\$IAM_ROLE_ARN" ]; do
        echo "IAM Role ARN is required."
        read -p "Enter IAM Role ARN for service execution: " IAM_ROLE_ARN
    done
    
    read -p "Enter Bedrock model ID [\$MODEL_ID]: " input_model
    MODEL_ID=\${input_model:-\$MODEL_ID}
    
    validate_s3_bucket
}

# Function to add new agent
add_agent() {
    echo "Add New Agent"
    echo "=============="
    
    echo "Select tier for new agent:"
    echo "1. Executive Tier"
    echo "2. Structural Tier"
    echo "3. Content Development Tier"
    echo "4. Editorial Tier"
    echo "5. Market Positioning Tier"
    
    read -p "Select tier (1-5): " tier_choice
    
    read -p "Enter agent name (no spaces): " agent_name
    read -p "Enter agent prompt: " agent_prompt
    
    case \$tier_choice in
        1)
            EXECUTIVE_TIER["\$agent_name"]="\$agent_prompt"
            echo "Agent \$agent_name added to Executive Tier."
            ;;
        2)
            STRUCTURAL_TIER["\$agent_name"]="\$agent_prompt"
            echo "Agent \$agent_name added to Structural Tier."
            ;;
        3)
            CONTENT_TIER["\$agent_name"]="\$agent_prompt"
            echo "Agent \$agent_name added to Content Development Tier."
            ;;
        4)
            EDITORIAL_TIER["\$agent_name"]="\$agent_prompt"
            echo "Agent \$agent_name added to Editorial Tier."
            ;;
        5)
            MARKET_TIER["\$agent_name"]="\$agent_prompt"
            echo "Agent \$agent_name added to Market Positioning Tier."
            ;;
        *)
            echo "Invalid tier selection."
            ;;
    esac
}

# Function to edit agent prompt
edit_agent_prompt() {
    echo "Edit Agent Prompt"
    echo "================="
    
    echo "Select tier:"
    echo "1. Executive Tier"
    echo "2. Structural Tier"
    echo "3. Content Development Tier"
    echo "4. Editorial Tier"
    echo "5. Market Positioning Tier"
    
    read -p "Select tier (1-5): " tier_choice
    
    case \$tier_choice in
        1)
            declare -n tier_ref=EXECUTIVE_TIER
            echo "Executive Tier Agents:"
            ;;
        2)
            declare -n tier_ref=STRUCTURAL_TIER
            echo "Structural Tier Agents:"
            ;;
        3)
            declare -n tier_ref=CONTENT_TIER
            echo "Content Development Tier Agents:"
            ;;
        4)
            declare -n tier_ref=EDITORIAL_TIER
            echo "Editorial Tier Agents:"
            ;;
        5)
            declare -n tier_ref=MARKET_TIER
            echo "Market Positioning Tier Agents:"
            ;;
        *)
            echo "Invalid tier selection."
            return
            ;;
    esac
    
    # List agents in the tier
    i=1
    for agent_name in "\${!tier_ref[@]}"; do
        echo "\$i. \$agent_name"
        i=\$((i+1))
    done
    
    read -p "Select agent to edit (1-\$((i-1))): " agent_num
    
    # Find selected agent
    i=1
    for agent_name in "\${!tier_ref[@]}"; do
        if [ \$i -eq \$agent_num ]; then
            echo "Current prompt for \$agent_name:"
            echo "\${tier_ref[\$agent_name]}"
            echo ""
            read -p "Enter new prompt (or press Enter to cancel): " new_prompt
            
            if [ -n "\$new_prompt" ]; then
                tier_ref[\$agent_name]="\$new_prompt"
                echo "Prompt updated successfully."
            else
                echo "Prompt edit cancelled."
            fi
            break
        fi
        i=\$((i+1))
    done
}

# Function to remove agent
remove_agent() {
    echo "Remove Agent"
    echo "============"
    
    echo "Select tier:"
    echo "1. Executive Tier"
    echo "2. Structural Tier"
    echo "3. Content Development Tier"
    echo "4. Editorial Tier"
    echo "5. Market Positioning Tier"
    
    read -p "Select tier (1-5): " tier_choice
    
    case \$tier_choice in
        1)
            declare -n tier_ref=EXECUTIVE_TIER
            echo "Executive Tier Agents:"
            ;;
        2)
            declare -n tier_ref=STRUCTURAL_TIER
            echo "Structural Tier Agents:"
            ;;
        3)
            declare -n tier_ref=CONTENT_TIER
            echo "Content Development Tier Agents:"
            ;;
        4)
            declare -n tier_ref=EDITORIAL_TIER
            echo "Editorial Tier Agents:"
            ;;
        5)
            declare -n tier_ref=MARKET_TIER
            echo "Market Positioning Tier Agents:"
            ;;
        *)
            echo "Invalid tier selection."
            return
            ;;
    esac
    
    # List agents in the tier
    i=1
    for agent_name in "\${!tier_ref[@]}"; do
        echo "\$i. \$agent_name"
        i=\$((i+1))
    done
    
    read -p "Select agent to remove (1-\$((i-1))): " agent_num
    
    # Find and remove selected agent
    i=1
    for agent_name in "\${!tier_ref[@]}"; do
        if [ \$i -eq \$agent_num ]; then
            read -p "Are you sure you want to remove \$agent_name? (y/n): " confirm
            if [ "\$confirm" == "y" ]; then
                unset tier_ref[\$agent_name]
                echo "Agent \$agent_name removed successfully."
            else
                echo "Agent removal cancelled."
            fi
            break
        fi
        i=\$((i+1))
    done
}

# Function to create full deployment
create_deployment() {
    echo "Creating full deployment..."
    
    # Setup configuration
    setup_deployment
    
    # Initialize agent prompts
    initialize_agent_prompts
    
    # Create Lambda functions for text processing
    create_text_splitter_lambda
    create_text_merger_lambda
    
    # Generate flow definition and create flow
    generate_flow_definition
    create_flow
    
    echo "Deployment completed successfully."
}

# Function to modify deployment
modify_deployment() {
    echo "Modify Deployment"
    echo "================="
    echo "1. Add new agent"
    echo "2. Edit agent prompt"  
    echo "3. Remove agent"
    echo "4. Regenerate and update flow"
    echo "5. Return to main menu"
    
    read -p "Select an option: " modify_option
    
    case \$modify_option in
        1)
            add_agent
            ;;
        2)
            edit_agent_prompt
            ;;
        3)
            remove_agent
            ;;
        4)
            # Setup configuration if not already done
            if [ -z "\$S3_BUCKET" ] || [ -z "\$IAM_ROLE_ARN" ]; then
                setup_deployment
            fi
            update_flow
            ;;
        5)
            return
            ;;
        *)
            echo "Invalid option."
            ;;
    esac
    
    # Return to modify menu
    modify_deployment
}

# Function to delete deployment
delete_deployment() {
    echo "Deleting deployment..."
    
    read -p "Are you sure you want to delete the entire deployment? (y/n): " confirm
    if [ "\$confirm" != "y" ]; then
        echo "Deletion cancelled."
        return
    fi
    
    # Setup configuration if not already done
    if [ -z "\$S3_BUCKET" ]; then
        read -p "Enter S3 Bucket where flow definition is stored: " S3_BUCKET
    fi
    
    if [ -z "\$REGION" ]; then
        read -p "Enter AWS Region: " REGION
    fi
    
    delete_flow
    
    echo "Deployment deleted successfully."
}

# Main menu function
main_menu() {
    clear
    echo "=========================================="
    echo "  Hierarchical Multi-Agent Workflow Tool"
    echo "=========================================="
    echo "1. Create new deployment"
    echo "2. Modify existing deployment"
    echo "3. Delete deployment"
    echo "4. Exit"
    echo "=========================================="
    
    read -p "Select an option: " main_option
    
    case \$main_option in
        1)
            create_deployment
            ;;
        2)
            # Setup configuration if not already done
            if [ -z "\$S3_BUCKET" ] || [ -z "\$IAM_ROLE_ARN" ]; then
                setup_deployment
            fi
            
            # Initialize agent prompts
            initialize_agent_prompts
            
            modify_deployment
            ;;
        3)
            delete_deployment
            ;;
        4)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option."
            ;;
    esac
    
    read -p "Press Enter to continue..."
    main_menu
}

# Start script execution
check_aws_cli
main_menu
