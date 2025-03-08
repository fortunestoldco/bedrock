#!/bin/bash

# AWS Bedrock Flow Hierarchical Multi-Agent Deployment Script
# This script helps deploy, modify, or delete a complex Bedrock Flow for manuscript processing
# Requirements: AWS CLI v2.24 or higher, jq, proper AWS permissions

set -e

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Global variables
REGION="us-east-1" # Default region - modify if needed
STACK_NAME="ManuscriptProcessingFlow"
MODEL_ID="anthropic.claude-3-sonnet-20240229-v1:0" # Default model
FLOW_BUCKET_NAME="manuscript-flow-resources-\$(date +%s)"
ROLE_NAME="BedrockFlowManuscriptRole"
ACCOUNT_ID=\$(aws sts get-caller-identity --query Account --output text)

# Agent IDs - will be populated during creation
declare -A AGENT_IDS

# Check dependencies
check_dependencies() {
    echo -e "\${BLUE}Checking dependencies...\${NC}"
    
    if ! command -v aws &> /dev/null; then
        echo -e "\${RED}AWS CLI is not installed. Please install it and try again.\${NC}"
        exit 1
    fi
    
    AWS_VERSION=\$(aws --version | cut -d' ' -f1 | cut -d'/' -f2)
    if [[ \$(echo "\$AWS_VERSION 2.24" | awk '{if (\$1 < \$2) print "false"; else print "true"}') == "false" ]]; then
        echo -e "\${RED}AWS CLI version is \$AWS_VERSION, but 2.24 or higher is required.\${NC}"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        echo -e "\${RED}jq is not installed. Please install it and try again.\${NC}"
        exit 1
    fi
    
    echo -e "\${GREEN}All dependencies found.\${NC}"
}

# Create IAM role for Bedrock Flow
create_iam_role() {
    echo -e "\${BLUE}Creating IAM role for Bedrock Flow...\${NC}"
    
    # Check if role already exists
    if aws iam get-role --role-name \$ROLE_NAME &>/dev/null; then
        echo -e "\${YELLOW}Role \$ROLE_NAME already exists, skipping creation.\${NC}"
        return 0
    fi
    
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
                "arn:aws:s3:::\${FLOW_BUCKET_NAME}",
                "arn:aws:s3:::\${FLOW_BUCKET_NAME}/*"
            ]
        }
    ]
}
EOF

    # Create the role
    aws iam create-role \
        --role-name \$ROLE_NAME \
        --assume-role-policy-document file://trust-policy.json

    # Create and attach policy
    aws iam create-policy \
        --policy-name BedrockFlowManuscriptPolicy \
        --policy-document file://bedrock-policy.json

    aws iam attach-role-policy \
        --role-name \$ROLE_NAME \
        --policy-arn arn:aws:iam::\${ACCOUNT_ID}:policy/BedrockFlowManuscriptPolicy
    
    # Wait for role to propagate
    echo -e "\${YELLOW}Waiting 10 seconds for role to propagate...\${NC}"
    sleep 10
    
    echo -e "\${GREEN}IAM role created successfully.\${NC}"
    
    # Clean up
    rm -f trust-policy.json bedrock-policy.json
}

# Create S3 bucket for storing resources
create_s3_bucket() {
    echo -e "\${BLUE}Creating S3 bucket for flow resources...\${NC}"
    
    aws s3 mb s3://\${FLOW_BUCKET_NAME} --region \$REGION
    
    # Enable versioning for backup
    aws s3api put-bucket-versioning \
        --bucket \${FLOW_BUCKET_NAME} \
        --versioning-configuration Status=Enabled
        
    echo -e "\${GREEN}S3 bucket created successfully.\${NC}"
}

# Upload agent prompts to S3
upload_prompts() {
    echo -e "\${BLUE}Creating and uploading agent prompts to S3...\${NC}"
    
    mkdir -p prompts
    
    # Create prompts for all agents
    cat > prompts/executive_director.md << EOF
# Executive Director Agent Prompt

You are the Executive Director of a manuscript processing system. Your role is to:
- Orchestrate the entire workflow and coordinate all agents
- Maintain a global vision of manuscript goals and quality
- Make final decisions on major revisions
- Interface between the system and the human author

## INSTRUCTIONS:
1. Assess the manuscript's current state and identify the highest priority areas for improvement
2. Coordinate the work of all specialized agents in the system
3. Track overall progress and guide the manuscript through the revision process
4. Make executive decisions when agents have conflicting recommendations
5. Provide clear summaries to the human author of changes made and reasoning
6. Always maintain the original creative vision and voice of the manuscript

## MANUSCRIPT ANALYSIS:
When analyzing a manuscript, consider:
- Overall narrative structure and flow
- Character development and arcs
- Pacing and engagement
- Thematic coherence
- Commercial viability
- Technical quality of writing

## OUTPUTS:
Provide concise, actionable guidance that includes:
1. Executive summary of manuscript status
2. Priority areas requiring attention
3. Specific instructions for specialized agents
4. Timeline for implementation
5. Clear rationale for decisions made

Remember that you hold the global vision for the manuscript. Focus on coordinating the specialized expertise of other agents while ensuring the final product maintains creative integrity and meets market standards.
EOF

    cat > prompts/creative_director.md << EOF
# Creative Director Agent Prompt

You are the Creative Director of a manuscript processing system. Your role is to:
- Define and protect core creative elements of the manuscript
- Balance commercial considerations with artistic integrity
- Guide stylistic decisions throughout the revision process
- Ensure the manuscript maintains its distinctive voice

## INSTRUCTIONS:
1. Identify the core creative elements that make this manuscript unique
2. Establish stylistic guidelines for all other agents to follow
3. Review proposed changes for creative consistency
4. Push back on suggestions that compromise artistic integrity
5. Enhance distinctive elements that set the manuscript apart
6. Ensure the author's original voice remains intact

## CREATIVE ASSESSMENT:
When reviewing a manuscript, analyze:
- Distinctive voice and tone
- Unique stylistic elements
- Core themes and motifs
- Artistic risks and innovations
- Genre conventions and subversions
- Emotional resonance

## OUTPUTS:
Provide clear creative guidance that includes:
1. Creative vision statement for the manuscript
2. Stylistic guidelines for maintaining voice consistency
3. Recommendations for enhancing distinctive elements
4. Identification of areas where commercial needs may conflict with artistic vision
5. Solutions that balance marketability with creative integrity

Remember that you are the guardian of the manuscript's artistic soul. Your decisions should protect what makes this work special while allowing necessary improvements to reach its full potential.
EOF

    # Create prompts for remaining agents (abbreviated for length)
    # In a full implementation, each agent would have a unique prompt
    for agent in "human_feedback_manager" "quality_assessment_director" "project_timeline_manager" "market_alignment_director" "structure_architect" "plot_development_specialist" "world_building_expert" "character_psychology_specialist" "character_voice_designer" "character_relationship_mapper" "domain_knowledge_specialist" "cultural_authenticity_expert" "content_development_director" "chapter_drafters" "scene_construction_specialists" "dialogue_crafters" "continuity_manager" "voice_consistency_monitor" "emotional_arc_designer" "editorial_director" "structural_editor" "character_arc_evaluator" "thematic_coherence_analyst" "prose_enhancement_specialist" "dialogue_refinement_expert" "rhythm_cadence_optimizer" "grammar_consistency_checker" "fact_verification_specialist" "positioning_specialist" "title_blurb_optimizer" "differentiation_strategist" "formatting_standards_expert"; do
        cat > prompts/\${agent}.md << EOF
# \${agent^} Agent Prompt

You are the \${agent^} in a manuscript processing system. Your specialized role focuses on specific aspects of manuscript enhancement.

## INSTRUCTIONS:
1. Review the manuscript section with focus on your specialty
2. Identify issues and opportunities for improvement
3. Provide specific, actionable recommendations
4. Maintain consistency with the manuscript's voice and vision
5. Collaborate with other agents as needed

## ANALYSIS FOCUS:
[Specific analysis areas for this agent role]

## OUTPUTS:
Provide specialized recommendations including:
1. Identified issues in your domain expertise
2. Specific suggested improvements
3. Implementation guidance
4. Reasoning for recommendations

Remember to stay focused on your specific area of expertise while maintaining awareness of the manuscript's overall goals.
EOF
    done

    # Create text splitter utility
    cat > prompts/text_splitter.md << EOF
# Text Splitting Utility

You are a utility designed to split large manuscript texts into manageable chunks while preserving context.

## INSTRUCTIONS:
1. Split text at natural boundaries (chapters, scenes) whenever possible
2. Ensure each chunk contains enough context for processing
3. Maintain a small overlap between chunks for continuity
4. Track metadata including position in overall manuscript
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
    aws s3 sync prompts/ s3://\${FLOW_BUCKET_NAME}/prompts/ --region \$REGION
    
    echo -e "\${GREEN}Agent prompts uploaded successfully.\${NC}"
    
    # Clean up
    rm -rf prompts
}

# Create agent function to reduce repetition
create_agent() {
    local agent_name=\$1
    local agent_desc=\$2
    local prompt_s3_path=\$3
    
    echo -e "\${BLUE}Creating agent: \$agent_name...\${NC}"
    
    # Create agent with Claude 3 Sonnet
    RESPONSE=\$(aws bedrock-agent create-agent \
        --agent-name "\$agent_name" \
        --agent-resource-role-arn "arn:aws:iam::\${ACCOUNT_ID}:role/\${ROLE_NAME}" \
        --instruction-configuration "s3={bucketName=\${FLOW_BUCKET_NAME},objectKey=\${prompt_s3_path}}" \
        --foundation-model "\$MODEL_ID" \
        --description "\$agent_desc" \
        --idle-session-timeout-in-seconds 1800 \
        --region \$REGION)
    
    # Extract agent ID
    AGENT_ID=\$(echo \$RESPONSE | jq -r '.agent.agentId')
    AGENT_IDS["\$agent_name"]=\$AGENT_ID
    
    echo -e "\${GREEN}Created agent: \$agent_name with ID: \$AGENT_ID\${NC}"
    
    # Wait for agent creation
    echo -e "\${YELLOW}Waiting for agent to be ready...\${NC}"
    aws bedrock-agent wait agent-available \
        --agent-id \$AGENT_ID \
        --region \$REGION
    
    # Create agent alias
    ALIAS_RESPONSE=\$(aws bedrock-agent create-agent-alias \
        --agent-id \$AGENT_ID \
        --agent-alias-name "Production" \
        --routing-configuration "provisionedThroughput={standardThroughput=1}" \
        --region \$REGION)
    
    # Extract alias ID
    ALIAS_ID=\$(echo \$ALIAS_RESPONSE | jq -r '.agentAlias.agentAliasId')
    
    echo -e "\${GREEN}Created alias for \$agent_name\${NC}"
    
    # Prepare agent for use
    aws bedrock-agent prepare-agent \
        --agent-id \$AGENT_ID \
        --region \$REGION
        
    echo -e "\${GREEN}Agent \$agent_name is ready\${NC}"
}

# Create all agents in the system
create_agents() {
    echo -e "\${BLUE}Creating all agents for manuscript processing workflow...\${NC}"
    
    # Create Executive Tier Agents
    create_agent "ExecutiveDirector" "System orchestrator and final decision-maker" "prompts/executive_director.md"
    create_agent "CreativeDirector" "Guardian of the manuscript's artistic vision" "prompts/creative_director.md"
    create_agent "HumanFeedbackManager" "Interpreter of author intentions and external feedback" "prompts/human_feedback_manager.md"
    create_agent "QualityAssessmentDirector" "Objective evaluator of manuscript progression" "prompts/quality_assessment_director.md"
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
    create_agent "TextSplitter" "Utility for splitting large manuscripts" "prompts/text_splitter.md"
    
    echo -e "\${GREEN}All agents created successfully.\${NC}"
    
    # Save agent IDs to file for later use
    echo "Saving agent IDs to file for reference..."
    declare -p AGENT_IDS > agent_ids.txt
}

# Create the Bedrock Flow
create_flow() {
    echo -e "\${BLUE}Creating Bedrock Flow for manuscript processing...\${NC}"
    
    # Create flow definition file
    cat > flow_definition.json << EOF
{
  "name": "ManuscriptProcessingFlow",
  "description": "A hierarchical multi-agent workflow for processing and enhancing manuscripts",
  "execution": {
    "timeoutMinutes": 240
  },
  "definition": {
    "flowNodes": [
      {
        "name": "InputNode",
        "type": "Input",
        "source": null,
        "inputs": {
          "flowInputs": {
            "title": "\\${title}",
            "manuscript": "\\${manuscript}"
          }
        },
        "outputs": {
          "title": "\\${title}",
          "manuscript": "\\${manuscript}"
        }
      },
      {
        "name": "TextSplitterNode",
        "type": "InvokeAgent",
        "source": "InputNode",
        "inputs": {
          "agentAliasId": "\${AGENT_IDS["TextSplitter"]}:Production",
          "inputText": "I need to split this manuscript for processing. Here are the details:\\nTitle: \\${title}\\n\\nManuscript:\\n\\${manuscript}"
        },
        "outputs": {
          "chunks": "\\${agentResponse}"
        }
      },
      {
        "name": "ExecutiveAssessment",
        "type": "InvokeAgent",
        "source": "TextSplitterNode",
        "inputs": {
          "agentAliasId": "\${AGENT_IDS["ExecutiveDirector"]}:Production",
          "inputText": "Please review this manuscript and provide an initial assessment:\\nTitle: \\${title}\\n\\nManuscript chunks:\\n\\${chunks}"
        },
        "outputs": {
          "executiveAssessment": "\\${agentResponse}"
        }
      },
      {
        "name": "CreativeVision",
        "type": "InvokeAgent",
        "source": "ExecutiveAssessment",
        "inputs": {
          "agentAliasId": "\${AGENT_IDS["CreativeDirector"]}:Production",
          "inputText": "Based on the executive assessment, please establish the creative vision for this manuscript:\\n\\nTitle: \\${title}\\n\\nExecutive Assessment: \\${executiveAssessment}\\n\\nManuscript chunks: \\${chunks}"
        },
        "outputs": {
          "creativeVision": "\\${agentResponse}"
        }
      },
      {
        "name": "MarketAnalysis",
        "type": "InvokeAgent",
        "source": "CreativeVision",
        "inputs": {
          "agentAliasId": "\${AGENT_IDS["MarketAlignmentDirector"]}:Production",
          "inputText": "Please analyze the market positioning for this manuscript:\\n\\nTitle: \\${title}\\n\\nExecutive Assessment: \\${executiveAssessment}\\n\\nCreative Vision: \\${creativeVision}"
        },
        "outputs": {
          "marketAnalysis": "\\${agentResponse}"
        }
      },
      {
        "name": "StructuralAssessment",
        "type": "InvokeAgent",
        "source": "MarketAnalysis",
        "inputs": {
          "agentAliasId": "\${AGENT_IDS["StructureArchitect"]}:Production",
          "inputText": "Please analyze the structural elements of this manuscript:\\n\\nTitle: \\${title}\\n\\nExecutive Assessment: \\${executiveAssessment}\\n\\nCreative Vision: \\${creativeVision}\\n\\nMarket Analysis: \\${marketAnalysis}\\n\\nManuscript chunks: \\${chunks}"
        },
        "outputs": {
          "structuralAssessment": "\\${agentResponse}"
        }
      },
      {
        "name": "CharacterAssessment",
        "type": "InvokeAgent",
        "source": "StructuralAssessment",
        "inputs": {
          "agentAliasId": "\${AGENT_IDS["CharacterPsychologySpecialist"]}:Production",
          "inputText": "Please analyze the character elements of this manuscript:\\n\\nTitle: \\${title}\\n\\nStructural Assessment: \\${structuralAssessment}\\n\\nCreative Vision: \\${creativeVision}\\n\\nManuscript chunks: \\${chunks}"
        },
        "outputs": {
          "characterAssessment": "\\${agentResponse}"
        }
      },
      {
        "name": "ContentRefinementPlan",
        "type": "InvokeAgent",
        "source": "CharacterAssessment",
        "inputs": {
          "agentAliasId": "\${AGENT_IDS["ContentDevelopmentDirector"]}:Production",
          "inputText": "Please develop a content refinement plan for this manuscript:\\n\\nTitle: \\${title}\\n\\nExecutive Assessment: \\${executiveAssessment}\\n\\nStructural Assessment: \\${structuralAssessment}\\n\\nCharacter Assessment: \\${characterAssessment}\\n\\nCreative Vision: \\${creativeVision}\\n\\nMarket Analysis: \\${marketAnalysis}"
        },
        "outputs": {
          "contentPlan": "\\${agentResponse}"
        }
      },
      {
        "name": "EditorialDirection",
        "type": "InvokeAgent",
        "source": "ContentRefinementPlan",
        "inputs": {
          "agentAliasId": "\${AGENT_IDS["EditorialDirector"]}:Production",
          "inputText": "Please establish editorial direction for this manuscript:\\n\\nTitle: \\${title}\\n\\nContent Plan: \\${contentPlan}\\n\\nCreative Vision: \\${creativeVision}\\n\\nStructural Assessment: \\${structuralAssessment}\\n\\nCharacter Assessment: \\${characterAssessment}"
        },
        "outputs": {
          "editorialDirection": "\\${agentResponse}"
        }
      },
      {
        "name": "ProseRefinement",
        "type": "InvokeAgent",
        "source": "EditorialDirection",
        "inputs": {
          "agentAliasId": "\${AGENT_IDS["ProseEnhancementSpecialist"]}:Production",
          "inputText": "Please enhance the prose of this manuscript based on the editorial direction:\\n\\nTitle: \\${title}\\n\\nEditorial Direction: \\${editorialDirection}\\n\\nCreative Vision: \\${creativeVision}\\n\\nManuscript chunks: \\${chunks}"
        },
        "outputs": {
          "enhancedProse": "\\${agentResponse}"
        }
      },
      {
        "name": "FinalRevision",
        "type": "InvokeAgent",
        "source": "ProseRefinement",
        "inputs": {
          "agentAliasId": "\${AGENT_IDS["ExecutiveDirector"]}:Production",
          "inputText": "Please review and finalize the manuscript with all enhancements:\\n\\nTitle: \\${title}\\n\\nEnhanced Prose: \\${enhancedProse}\\n\\nEditorial Direction: \\${editorialDirection}\\n\\nContent Plan: \\${contentPlan}\\n\\nStructural Assessment: \\${structuralAssessment}\\n\\nCharacter Assessment: \\${characterAssessment}\\n\\nCreative Vision: \\${creativeVision}\\n\\nMarket Analysis: \\${marketAnalysis}"
        },
        "outputs": {
          "finalManuscript": "\\${agentResponse}"
        }
      },
      {
        "name": "OutputNode",
        "type": "Output",
        "source": "FinalRevision",
        "inputs": {
          "flowOutputs": {
            "originalTitle": "\\${title}",
            "polishedManuscript": "\\${finalManuscript}",
            "executiveSummary": "\\${executiveAssessment}",
            "creativeVision": "\\${creativeVision}",
            "marketAnalysis": "\\${marketAnalysis}"
          }
        },
        "outputs": {}
      }
    ]
  }
}
EOF

    # Create the flow
    FLOW_RESPONSE=\$(aws bedrock create-flow \
        --name "ManuscriptProcessingFlow" \
        --definition file://flow_definition.json \
        --execution-role-arn "arn:aws:iam::\${ACCOUNT_ID}:role/\${ROLE_NAME}" \
        --region \$REGION)
    
    # Extract flow ID
    FLOW_ID=\$(echo \$FLOW_RESPONSE | jq -r '.id')
    
    echo -e "\${GREEN}Created flow with ID: \$FLOW_ID\${NC}"
    
    # Create flow alias
    FLOW_ALIAS_RESPONSE=\$(aws bedrock create-flow-alias \
        --flow-id \$FLOW_ID \
        --name "Production" \
        --region \$REGION)
    
    # Extract flow alias ID
    FLOW_ALIAS_ID=\$(echo \$FLOW_ALIAS_RESPONSE | jq -r '.id')
    
    echo -e "\${GREEN}Created flow alias with ID: \$FLOW_ALIAS_ID\${NC}"
    
    # Save flow information to file
    echo "FLOW_ID=\$FLOW_ID" > flow_info.txt
    echo "FLOW_ALIAS_ID=\$FLOW_ALIAS_ID" >> flow_info.txt
    
    echo -e "\${GREEN}Flow created and configured successfully.\${NC}"
    
    # Clean up
    rm -f flow_definition.json
}

# Function to create all resources
create_resources() {
    check_dependencies
    create_iam_role
    create_s3_bucket
    upload_prompts
    create_agents
    create_flow
    
    echo -e "\${GREEN}All resources created successfully.\${NC}"
    echo -e "\${BLUE}Your manuscript processing flow is ready to use.\${NC}"
    echo -e "\${BLUE}Flow ID: \$FLOW_ID\${NC}"
    echo -e "\${BLUE}Flow Alias: Production (ID: \$FLOW_ALIAS_ID)\${NC}"
    echo -e "\${BLUE}S3 Bucket: \$FLOW_BUCKET_NAME\${NC}"
}

# Function to modify resources
modify_resources() {
    echo -e "\${YELLOW}Modifying existing resources is not fully implemented.\${NC}"
    echo -e "\${YELLOW}For significant changes, it's recommended to delete and recreate the flow.\${NC}"
    
    # Here you would include logic to modify specific aspects of the flow
    # This would require loading existing IDs from saved files
    
    echo -e "\${BLUE}Options for modification:\${NC}"
    echo -e "1. Update agent prompts"
    echo -e "2. Modify flow definition"
    echo -e "3. Return to main menu"
    
    read -p "Choose an option: " modify_option
    
    case \$modify_option in
        1)
            echo -e "\${BLUE}Updating agent prompts...\${NC}"
            # Logic to update prompts would go here
            ;;
        2)
            echo -e "\${BLUE}Modifying flow definition...\${NC}"
            # Logic to modify flow would go here
            ;;
        3)
            return
            ;;
        *)
            echo -e "\${RED}Invalid option\${NC}"
            ;;
    esac
}

# Function to delete all resources
delete_resources() {
    echo -e "\${RED}WARNING: This will delete all resources created for the manuscript processing flow.\${NC}"
    read -p "Are you sure you want to proceed? (y/n): " confirm
    
    if [[ \$confirm != "y" && \$confirm != "Y" ]]; then
        echo -e "\${BLUE}Deletion cancelled.\${NC}"
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
    
    echo -e "\${BLUE}Deleting flow...\${NC}"
    # Delete flow alias first
    if [ ! -z "\$FLOW_ALIAS_ID" ] && [ ! -z "\$FLOW_ID" ]; then
        aws bedrock delete-flow-alias \
            --flow-id \$FLOW_ID \
            --flow-alias-id \$FLOW_ALIAS_ID \
            --region \$REGION || true
        
        # Delete flow
        aws bedrock delete-flow \
            --flow-id \$FLOW_ID \
            --region \$REGION || true
    fi
    
    echo -e "\${BLUE}Deleting agents...\${NC}"
    # Delete all agents if agent_ids.txt exists
    if [ -v AGENT_IDS ]; then
        for agent_name in "\${!AGENT_IDS[@]}"; do
            agent_id=\${AGENT_IDS[\$agent_name]}
            echo -e "Deleting agent: \$agent_name (\$agent_id)"
            
            # Delete agent alias
            aws bedrock-agent delete-agent-alias \
                --agent-id \$agent_id \
                --agent-alias-id Production \
                --region \$REGION || true
            
            # Delete agent
            aws bedrock-agent delete-agent \
                --agent-id \$agent_id \
                --skip-resource-in-use-check \
                --region \$REGION || true
        done
    fi
    
    echo -e "\${BLUE}Deleting S3 bucket...\${NC}"
    # Delete S3 bucket
    if [ ! -z "\$FLOW_BUCKET_NAME" ]; then
        aws s3 rm s3://\${FLOW_BUCKET_NAME} --recursive --region \$REGION
        aws s3 rb s3://\${FLOW_BUCKET_NAME} --force --region \$REGION
    fi
    
    echo -e "\${BLUE}Deleting IAM role...\${NC}"
    # Delete IAM role
    if [ ! -z "\$ROLE_NAME" ]; then
        aws iam detach-role-policy \
            --role-name \$ROLE_NAME \
            --policy-arn arn:aws:iam::\${ACCOUNT_ID}:policy/BedrockFlowManuscriptPolicy || true
        
        aws iam delete-policy \
            --policy-arn arn:aws:iam::\${ACCOUNT_ID}:policy/BedrockFlowManuscriptPolicy || true
        
        aws iam delete-role \
            --role-name \$ROLE_NAME || true
    fi
    
    # Remove info files
    rm -f flow_info.txt agent_ids.txt
    
    echo -e "\${GREEN}All resources deleted successfully.\${NC}"
}

# Function to display information about a deployed flow
show_info() {
    echo -e "\${BLUE}Retrieving information about deployed resources...\${NC}"
    
    if [ -f flow_info.txt ]; then
        source flow_info.txt
        echo -e "\${GREEN}Flow Information:\${NC}"
        echo -e "Flow ID: \$FLOW_ID"
        echo -e "Flow Alias ID: \$FLOW_ALIAS_ID"
        
        # Get flow details
        aws bedrock get-flow \
            --flow-id \$FLOW_ID \
            --region \$REGION | jq '.name, .description, .status'
    else
        echo -e "\${YELLOW}Flow information not found. Has a flow been deployed?\${NC}"
    fi
    
    if [ -f agent_ids.txt ]; then
        source agent_ids.txt
        echo -e "\${GREEN}Agent Information:\${NC}"
        for agent_name in "\${!AGENT_IDS[@]}"; do
            agent_id=\${AGENT_IDS[\$agent_name]}
            echo -e "\$agent_name: \$agent_id"
        done
    else
        echo -e "\${YELLOW}Agent information not found. Have agents been deployed?\${NC}"
    fi
    
    echo -e "\${GREEN}S3 Bucket: \$FLOW_BUCKET_NAME\${NC}"
}

# Function to test the flow with a sample manuscript
test_flow() {
    echo -e "\${BLUE}Testing the manuscript processing flow...\${NC}"
    
    if [ ! -f flow_info.txt ]; then
        echo -e "\${RED}Flow information not found. Please deploy the flow first.\${NC}"
        return
    fi
    
    source flow_info.txt
    
    # Create a small test manuscript
    cat > test_manuscript.json << EOF
{
  "title": "The Test Manuscript",
  "manuscript": "Chapter 1: The Beginning\n\nIt was a dark and stormy night. The protagonist couldn't sleep, tossing and turning as the rain beat against the window. Tomorrow would bring new challenges, but for now, the quiet of the night was both comforting and unsettling.\n\nChapter 2: The Discovery\n\nThe morning brought unexpected news. What seemed like an ordinary day would soon reveal secrets that had been buried for decades."
}
EOF

    echo -e "\${BLUE}Invoking flow with test manuscript...\${NC}"
    
    # Invoke the flow
    INVOKE_RESPONSE=\$(aws bedrock invoke-flow \
        --flow-id \$FLOW_ID \
        --flow-alias "Production" \
        --inputs file://test_manuscript.json \
        --region \$REGION)
    
    # Extract execution ID
    EXECUTION_ID=\$(echo \$INVOKE_RESPONSE | jq -r '.executionId')
    
    echo -e "\${GREEN}Flow execution started with ID: \$EXECUTION_ID\${NC}"
    echo -e "\${YELLOW}This may take several minutes to complete...\${NC}"
    
    # Wait for flow to complete
    aws bedrock wait flow-execution-complete \
        --flow-id \$FLOW_ID \
        --execution-id \$EXECUTION_ID \
        --region \$REGION
    
    echo -e "\${GREEN}Flow execution completed.\${NC}"
    
    # Get execution results
    RESULT=\$(aws bedrock get-flow-execution \
        --flow-id \$FLOW_ID \
        --execution-id \$EXECUTION_ID \
        --region \$REGION)
    
    # Extract outputs
    echo \$RESULT | jq -r '.outputs.polishedManuscript' > polished_manuscript.txt
    
    echo -e "\${GREEN}Test completed. Polished manuscript saved to polished_manuscript.txt\${NC}"
    
    # Clean up
    rm -f test_manuscript.json
}

# Main menu function
main_menu() {
    while true; do
        echo -e "\n\${BLUE}=== AWS Bedrock Flow Hierarchical Multi-Agent Deployment ====\${NC}"
        echo -e "1. Create manuscript processing flow"
        echo -e "2. Modify existing flow"
        echo -e "3. Delete all resources"
        echo -e "4. Show information about deployed resources"
        echo -e "5. Test flow with sample manuscript"
        echo -e "6. Exit"
        
        read -p "Choose an option: " option
        
        case \$option in
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
                echo -e "\${GREEN}Exiting. Goodbye!\${NC}"
                exit 0
                ;;
            *)
                echo -e "\${RED}Invalid option. Please try again.\${NC}"
                ;;
        esac
    done
}

# Script start
echo -e "\${BLUE}AWS Bedrock Flow Hierarchical Multi-Agent Deployment Script\${NC}"
echo -e "\${BLUE}This script will help you deploy a complex multi-agent workflow for manuscript processing\${NC}"
main_menu
