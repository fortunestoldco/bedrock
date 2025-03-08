import json
import logging
import time
import boto3
from botocore.exceptions import ClientError
from typing import Dict, List, Any, Optional, Tuple

logger = logging.getLogger("storybook.flows")

class FlowManager:
    """Manages Bedrock flows for storybook."""
    
    def __init__(self, config, iam_manager):
        """Initialize Flow manager with configuration."""
        self.config = config
        self.iam_manager = iam_manager
    
    def list_projects(self) -> List[str]:
        """List existing projects."""
        try:
            with open(self.config.FLOWS_LIST_FILE, 'r') as f:
                data = json.load(f)
                return data.get('flows', [])
        except Exception as e:
            logger.error(f"Error listing projects: {str(e)}")
            return []
    
    def project_exists(self, project_name: str) -> bool:
        """Check if a project already exists."""
        projects = self.list_projects()
        return project_name in projects
    
    def add_project_to_list(self, project_name: str) -> None:
        """Add a project to the flows list."""
        try:
            with open(self.config.FLOWS_LIST_FILE, 'r') as f:
                data = json.load(f)
            
            if project_name not in data.get('flows', []):
                data['flows'] = data.get('flows', []) + [project_name]
                
                with open(self.config.FLOWS_LIST_FILE, 'w') as f:
                    json.dump(data, f, indent=4)
                    
            logger.info(f"Added {project_name} to flows list")
            
        except Exception as e:
            logger.error(f"Error adding project to list: {str(e)}")
    
    def remove_project_from_list(self, project_name: str) -> None:
        """Remove a project from the flows list."""
        try:
            with open(self.config.FLOWS_LIST_FILE, 'r') as f:
                data = json.load(f)
            
            if project_name in data.get('flows', []):
                data['flows'] = [p for p in data.get('flows', []) if p != project_name]
                
                with open(self.config.FLOWS_LIST_FILE, 'w') as f:
                    json.dump(data, f, indent=4)
                    
            logger.info(f"Removed {project_name} from flows list")
            
        except Exception as e:
            logger.error(f"Error removing project from list: {str(e)}")
    
    def generate_templates(self, project_name: str, role_arn: str) -> None:
        """Generate flow templates for each phase."""
        self._generate_assessment_flow(f"{project_name}-assessment", role_arn)
        self._generate_improvement_flow(f"{project_name}-improvement", role_arn)
        self._generate_research_flow(f"{project_name}-research", role_arn)
        self._generate_finalization_flow(f"{project_name}-finalization", role_arn)
    
    def create_flows(self, project_name: str) -> Dict[str, Dict[str, str]]:
        """Create flows in AWS Bedrock."""
        flow_info = {}
        
        # Create each flow
        for phase in ['assessment', 'improvement', 'research', 'finalization']:
            logger.info(f"Creating {phase} flow...")
            flow_id, version, alias_id = self._create_flow(f"{project_name}-{phase}")
            
            if flow_id:
                flow_info[phase] = {
                    "flow_id": flow_id,
                    "version": version,
                    "alias_id": alias_id
                }
            else:
                logger.error(f"Failed to create {phase} flow")
        
        return flow_info
    
    def save_project_config(self, project_name: str, manuscript_title: str, 
                          flow_info: Dict[str, Dict[str, str]]) -> None:
        """Save flow details to project configuration file."""
        project_config = f"{project_name}_config.json"
        
        config_data = {
            "project_name": project_name,
            "title": manuscript_title,
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "original_manuscript": f"{self.config.MANUSCRIPT_DIR}/{project_name}_original.txt",
            "flows": flow_info
        }
        
        with open(project_config, 'w') as f:
            json.dump(config_data, f, indent=4)
            
        logger.info(f"Project configuration saved to {project_config}")
    
    def _create_flow(self, flow_name: str) -> Tuple[str, str, str]:
        """Create a flow in AWS Bedrock."""
        region = self.config.aws_region
        profile = self.config.aws_profile
        
        template_file = f"{self.config.FLOW_TEMPLATES_DIR}/{flow_name}.json"
        
        try:
            # Read the template
            with open(template_file, 'r') as f:
                template = json.load(f)
            
            # Create session and client
            session = boto3.Session(region_name=region, profile_name=profile)
            bedrock_agent = session.client('bedrock-agent')
            
            # Create flow
            response = bedrock_agent.create_flow(
                name=template['name'],
                description=template['description'],
                executionRoleArn=template['executionRoleArn'],
                definition=template['definition']
            )
            
            flow_id = response['id']
            logger.info(f"Flow created with ID: {flow_id}")
            
            # Prepare flow
            bedrock_agent.prepare_flow(flowIdentifier=flow_id)
            logger.info(f"Flow prepared: {flow_id}")
            
            # Create flow version
            version_response = bedrock_agent.create_flow_version(flowIdentifier=flow_id)
            version = version_response.get('version', '1')
            logger.info(f"Created version: {version}")
            
            # Create flow alias
            alias_response = bedrock_agent.create_flow_alias(
                flowIdentifier=flow_id,
                name="latest",
                routingConfiguration=[{"flowVersion": version}]
            )
            
            alias_id = alias_response.get('id', 'alias-placeholder')
            logger.info(f"Created alias: {alias_id}")
            
            return flow_id, version, alias_id
            
        except Exception as e:
            logger.error(f"Error creating flow {flow_name}: {str(e)}")
            return "", "", ""
    
    def delete_flows(self, project_name: str) -> bool:
        """Delete flows for a project."""
        region = self.config.aws_region
        profile = self.config.aws_profile
        
        # Check if project config exists
        project_config_file = f"{project_name}_config.json"
        
        try:
            # Create session and client
            session = boto3.Session(region_name=region, profile_name=profile)
            bedrock_agent = session.client('bedrock-agent')
            
            if os.path.isfile(project_config_file):
                # Delete based on project config
                with open(project_config_file, 'r') as f:
                    config = json.load(f)
                
                flows = config.get('flows', {})
                
                for phase, flow_info in flows.items():
                    flow_id = flow_info.get('flow_id')
                    alias_id = flow_info.get('alias_id')
                    
                    if flow_id and alias_id:
                        # Delete alias
                        try:
                            logger.info(f"Deleting alias {alias_id}")
                            bedrock_agent.delete_flow_alias(
                                flowIdentifier=flow_id,
                                aliasIdentifier=alias_id
                            )
                        except Exception as e:
                            logger.warning(f"Error deleting alias: {str(e)}")
                        
                        # List and delete versions
                        try:
                            versions_response = bedrock_agent.list_flow_versions(flowIdentifier=flow_id)
                            versions = [v['version'] for v in versions_response.get('versions', [])]
                            
                            for version in versions:
                                logger.info(f"Deleting version {version}")
                                bedrock_agent.delete_flow_version(
                                    flowIdentifier=flow_id,
                                    flowVersion=version
                                )
                        except Exception as e:
                            logger.warning(f"Error deleting versions: {str(e)}")
                        
                        # Delete flow
                        try:
                            logger.info(f"Deleting flow {flow_id}")
                            bedrock_agent.delete_flow(flowIdentifier=flow_id)
                        except Exception as e:
                            logger.warning(f"Error deleting flow: {str(e)}")
            else:
                # Find flows by name pattern
                try:
                    flows_response = bedrock_agent.list_flows()
                    
                    for flow in flows_response.get('flowSummaries', []):
                        if flow['name'].startswith(f"{project_name}-"):
                            flow_id = flow['id']
                            
                            # Delete aliases
                            try:
                                aliases_response = bedrock_agent.list_flow_aliases(flowIdentifier=flow_id)
                                
                                for alias in aliases_response.get('flowAliases', []):
                                    logger.info(f"Deleting alias {alias['id']}")
                                    bedrock_agent.delete_flow_alias(
                                        flowIdentifier=flow_id,
                                        aliasIdentifier=alias['id']
                                    )
                            except Exception as e:
                                logger.warning(f"Error deleting aliases: {str(e)}")
                            
                            # List and delete versions
                            try:
                                versions_response = bedrock_agent.list_flow_versions(flowIdentifier=flow_id)
                                
                                for version in versions_response.get('versions', []):
                                    logger.info(f"Deleting version {version['version']}")
                                    bedrock_agent.delete_flow_version(
                                        flowIdentifier=flow_id,
                                        flowVersion=version['version']
                                    )
                            except Exception as e:
                                logger.warning(f"Error deleting versions: {str(e)}")
                            
                            # Delete flow
                            try:
                                logger.info(f"Deleting flow {flow_id}")
                                bedrock_agent.delete_flow(flowIdentifier=flow_id)
                            except Exception as e:
                                logger.warning(f"Error deleting flow: {str(e)}")
                except Exception as e:
                    logger.warning(f"Error listing flows: {str(e)}")
            
            logger.info(f"Flows for project {project_name} have been deleted")
            return True
            
        except Exception as e:
            logger.error(f"Error deleting flows: {str(e)}")
            return False
    
    def invoke_flow(self, flow_id: str, alias_id: str, inputs: List[Dict[str, Any]]) -> Dict[str, Any]:
        """Invoke a Bedrock flow."""
        region = self.config.aws_region
        profile = self.config.aws_profile
        
        try:
            # Create session and client
            session = boto3.Session(region_name=region, profile_name=profile)
            bedrock_agent_runtime = session.client('bedrock-agent-runtime')
            
            # Invoke flow
            response = bedrock_agent_runtime.invoke_flow(
                flowIdentifier=flow_id,
                flowAliasIdentifier=alias_id,
                inputs=inputs
            )
            
            return response
            
        except Exception as e:
            logger.error(f"Error invoking flow: {str(e)}")
            return {}
    
    def _generate_assessment_flow(self, flow_name: str, role_arn: str) -> None:
        """Generate flow JSON for manuscript assessment."""
        # Get model IDs
        executive_model = self.config.get_config_value('models.executive_editor', self.config.default_model)
        content_assessor_model = self.config.get_config_value('models.content_assessor', self.config.default_model)
        dev_editor_model = self.config.get_config_value('models.developmental_editor', self.config.default_model)
        style_model = self.config.get_config_value('models.style_specialist', self.config.default_model)
        plot_model = self.config.get_config_value('models.plot_structure_analyst', self.config.default_model)
        
        # Create flow definition (see original script for the full template)
        flow_def = {
            "name": flow_name,
            "description": "Manuscript assessment flow for novel editing system",
            "executionRoleArn": role_arn,
            "definition": {
                "nodes": [
                    # Input node
                    {
                        "type": "Input",
                        "name": "FlowInputNode",
                        "outputs": [
                            { "name": "manuscript_id", "type": "String" },
                            { "name": "title", "type": "String" },
                            { "name": "sample_text", "type": "String" }
                        ]
                    },
                    # Executive Editor node
                    {
                        "type": "Prompt",
                        "name": "ExecutiveEditorNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": executive_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Executive Editor overseeing the improvement of a novel manuscript to best-seller quality. Manuscript ID: {{manuscript_id}}, Title: {{title}}. \n\nReview the following sample to determine which specialists should analyze this manuscript:\n\n{{sample_text}}\n\nProvide your assessment and recommendations in JSON format with these fields:\n- initial_impression\n- primary_areas_for_improvement (list at least 3)\n- recommended_specialists (list which of our specialists should focus on this manuscript)\n- estimated_improvement_potential (score 1-10)"
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "title", "type": "String", "expression": "$.title" },
                            { "name": "sample_text", "type": "String", "expression": "$.sample_text" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Content Assessment node
                    {
                        "type": "Prompt",
                        "name": "ContentAssessmentNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": content_assessor_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Content Assessment Specialist. Analyze this sample from manuscript '{{title}}' (ID: {{manuscript_id}}):\n\n{{sample_text}}\n\nProvide a detailed assessment focusing on:\n1. Writing style and voice consistency (score 1-10)\n2. Character development (score 1-10)\n3. Narrative structure and flow (score 1-10)\n4. Dialogue quality (score 1-10)\n5. Genre alignment and market potential\n6. Specific improvement recommendations to reach best-seller quality\n\nProvide your assessment in JSON format with scores for each area."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "title", "type": "String", "expression": "$.title" },
                            { "name": "sample_text", "type": "String", "expression": "$.sample_text" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Developmental Editor node
                    {
                        "type": "Prompt",
                        "name": "DevelopmentalEditorNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": dev_editor_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Developmental Editor. Analyze this sample from manuscript '{{title}}' (ID: {{manuscript_id}}):\n\n{{sample_text}}\n\nIdentify major developmental issues and provide strategic recommendations for improving:\n1. Plot structure and progression\n2. Character arcs and development\n3. Thematic coherence and depth\n4. Pacing and engagement\n5. Target audience alignment\n\nFor each issue, provide specific examples from the text and actionable guidance for revision. Include a development plan that would elevate this manuscript to best-seller quality."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "title", "type": "String", "expression": "$.title" },
                            { "name": "sample_text", "type": "String", "expression": "$.sample_text" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Style Specialist node
                    {
                        "type": "Prompt",
                        "name": "StyleSpecialistNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": style_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Style Specialist. Analyze this sample from manuscript '{{title}}' (ID: {{manuscript_id}}):\n\n{{sample_text}}\n\nEvaluate the prose style and provide detailed feedback on:\n1. Voice consistency and distinctiveness\n2. Syntax and sentence structure variety\n3. Word choice and vocabulary appropriateness\n4. Showing vs. telling balance\n5. Sensory details and imagery\n6. Overall rhythm and flow\n\nProvide specific examples of both strengths and weaknesses, with concrete suggestions for stylistic improvement to reach best-seller quality."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "title", "type": "String", "expression": "$.title" },
                            { "name": "sample_text", "type": "String", "expression": "$.sample_text" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Plot Structure node
                    {
                        "type": "Prompt",
                        "name": "PlotStructureNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": plot_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Plot Structure Analyst. Analyze this sample from manuscript '{{title}}' (ID: {{manuscript_id}}):\n\n{{sample_text}}\n\nEvaluate the narrative structure and provide insights on:\n1. Plot progression and key story beats\n2. Tension and conflict development\n3. Scene structure and function\n4. Subplot integration\n5. Pacing and momentum\n\nIdentify potential structure issues from what you can see in this sample, and suggest specific improvements that would make this more compelling and marketable as a best-seller."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "title", "type": "String", "expression": "$.title" },
                            { "name": "sample_text", "type": "String", "expression": "$.sample_text" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Integration Editor node
                    {
                        "type": "Prompt",
                        "name": "IntegrationEditorNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": executive_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Integration Editor. Compile and synthesize the assessments of all specialists for manuscript '{{title}}' (ID: {{manuscript_id}}).\n\nExecutive Editor assessment: {{executiveResult}}\n\nContent Assessment: {{contentResult}}\n\nDevelopmental Editor assessment: {{developmentalResult}}\n\nStyle Specialist assessment: {{styleResult}}\n\nPlot Structure analysis: {{plotResult}}\n\nProvide a comprehensive, integrated assessment that:\n1. Summarizes the key findings from all specialists\n2. Identifies the top 5 priority areas for improvement\n3. Outlines a strategic editing plan to elevate this manuscript to best-seller quality\n4. Lists specific recommendations for each major aspect of the manuscript\n5. Estimates overall improvement potential on a scale of 1-10\n\nYour assessment will guide the entire editing process for this manuscript."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "title", "type": "String", "expression": "$.title" },
                            { "name": "executiveResult", "type": "String", "expression": "$.ExecutiveEditorNode.modelCompletion" },
                            { "name": "contentResult", "type": "String", "expression": "$.ContentAssessmentNode.modelCompletion" },
                            { "name": "developmentalResult", "type": "String", "expression": "$.DevelopmentalEditorNode.modelCompletion" },
                            { "name": "styleResult", "type": "String", "expression": "$.StyleSpecialistNode.modelCompletion" },
                            { "name": "plotResult", "type": "String", "expression": "$.PlotStructureNode.modelCompletion" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Output node
                    {
                        "type": "Output",
                        "name": "FlowOutputNode",
                        "inputs": [
                            { "name": "executive_assessment", "type": "String", "expression": "$.ExecutiveEditorNode.modelCompletion" },
                            { "name": "content_assessment", "type": "String", "expression": "$.ContentAssessmentNode.modelCompletion" },
                            { "name": "developmental_assessment", "type": "String", "expression": "$.DevelopmentalEditorNode.modelCompletion" },
                            { "name": "style_assessment", "type": "String", "expression": "$.StyleSpecialistNode.modelCompletion" },
                            { "name": "plot_assessment", "type": "String", "expression": "$.PlotStructureNode.modelCompletion" },
                            { "name": "integrated_assessment", "type": "String", "expression": "$.IntegrationEditorNode.modelCompletion" }
                        ]
                    }
                ],
                "connections": [
                    # Connections (Input → nodes)
                    {
                        "name": "Input_to_ExecutiveEditor",
                        "source": "FlowInputNode",
                        "target": "ExecutiveEditorNode",
                        "type": "Data",
                        "configuration": {
                            "data": [
                                { "sourceOutput": "manuscript_id", "targetInput": "manuscript_id" },
                                { "sourceOutput": "title", "targetInput": "title" },
                                { "sourceOutput": "sample_text", "targetInput": "sample_text" }
                            ]
                        }
                    },
                    # Additional connections would be added here
                    # ...
                    # The complete connection configuration from the original script
                ]
            }
        }
        
        # Save flow definition to file
        with open(f"{self.config.FLOW_TEMPLATES_DIR}/{flow_name}.json", 'w') as f:
            json.dump(flow_def, f, indent=4)
            
        logger.info(f"Assessment flow template generated: {flow_name}")
    
    def _generate_improvement_flow(self, flow_name: str, role_arn: str) -> None:
        """Generate flow JSON for content improvement."""
        # Get model IDs
        text_improver_model = self.config.get_config_value('models.text_improver', self.config.default_model)
        line_editor_model = self.config.get_config_value('models.line_editor', self.config.default_model)
        style_specialist_model = self.config.get_config_value('models.style_specialist', self.config.default_model)
        pacing_analyst_model = self.config.get_config_value('models.pacing_analyst', self.config.default_model)
        dialogue_specialist_model = self.config.get_config_value('models.dialogue_specialist', self.config.default_model)
        
        # Create flow definition
        flow_def = {
            "name": flow_name,
            "description": "Content improvement flow for novel editing system",
            "executionRoleArn": role_arn,
            "definition": {
                "nodes": [
                    # Input node
                    {
                        "type": "Input",
                        "name": "FlowInputNode",
                        "outputs": [
                            { "name": "manuscript_id", "type": "String" },
                            { "name": "chunk_id", "type": "String" },
                            { "name": "chunk_text", "type": "String" },
                            { "name": "improvement_focus", "type": "String" },
                            { "name": "editing_notes", "type": "String" }
                        ]
                    },
                    # Text Improver node
                    {
                        "type": "Prompt",
                        "name": "TextImproverNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": text_improver_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Text Improver. Improve the following text from manuscript '{{manuscript_id}}' (Chunk ID: {{chunk_id}}):\n\n{{chunk_text}}\n\nFocus on the following areas for improvement: {{improvement_focus}}.\n\nProvide your improved version of the text."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "chunk_id", "type": "String", "expression": "$.chunk_id" },
                            { "name": "chunk_text", "type": "String", "expression": "$.chunk_text" },
                            { "name": "improvement_focus", "type": "String", "expression": "$.improvement_focus" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Line Editor node
                    {
                        "type": "Prompt",
                        "name": "LineEditorNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": line_editor_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Line Editor. Edit the following text from manuscript '{{manuscript_id}}' (Chunk ID: {{chunk_id}}):\n\n{{chunk_text}}\n\nFocus on improving clarity, coherence, and readability. Make sure the text flows smoothly and is free of grammatical errors."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "chunk_id", "type": "String", "expression": "$.chunk_id" },
                            { "name": "chunk_text", "type": "String", "expression": "$.TextImproverNode.modelCompletion" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Style Specialist node
                    {
                        "type": "Prompt",
                        "name": "StyleSpecialistNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": style_specialist_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Style Specialist. Review the following text from manuscript '{{manuscript_id}}' (Chunk ID: {{chunk_id}}):\n\n{{chunk_text}}\n\nFocus on enhancing the prose style, ensuring voice consistency, and improving overall readability."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "chunk_id", "type": "String", "expression": "$.chunk_id" },
                            { "name": "chunk_text", "type": "String", "expression": "$.LineEditorNode.modelCompletion" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Pacing Analyst node
                    {
                        "type": "Prompt",
                        "name": "PacingAnalystNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": pacing_analyst_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Pacing Analyst. Analyze the following text from manuscript '{{manuscript_id}}' (Chunk ID: {{chunk_id}}):\n\n{{chunk_text}}\n\nEvaluate the pacing and provide suggestions for improvement. Ensure the text maintains a good rhythm and keeps the reader engaged."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "chunk_id", "type": "String", "expression": "$.chunk_id" },
                            { "name": "chunk_text", "type": "String", "expression": "$.StyleSpecialistNode.modelCompletion" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Dialogue Specialist node
                    {
                        "type": "Prompt",
                        "name": "DialogueSpecialistNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": dialogue_specialist_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Dialogue Specialist. Review the following text from manuscript '{{manuscript_id}}' (Chunk ID: {{chunk_id}}):\n\n{{chunk_text}}\n\nFocus on improving the dialogue, ensuring it is natural, engaging, and true to the characters' voices."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "chunk_id", "type": "String", "expression": "$.chunk_id" },
                            { "name": "chunk_text", "type": "String", "expression": "$.PacingAnalystNode.modelCompletion" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Output node
                    {
                        "type": "Output",
                        "name": "FlowOutputNode",
                        "inputs": [
                            { "name": "final_revision", "type": "String", "expression": "$.DialogueSpecialistNode.modelCompletion" }
                        ]
                    }
                ],
                "connections": [
                    # Connections (Input → nodes)
                    {
                        "name": "Input_to_TextImprover",
                        "source": "FlowInputNode",
                        "target": "TextImproverNode",
                        "type": "Data",
                        "configuration": {
                            "data": [
                                { "sourceOutput": "manuscript_id", "targetInput": "manuscript_id" },
                                { "sourceOutput": "chunk_id", "targetInput": "chunk_id" },
                                { "sourceOutput": "chunk_text", "targetInput": "chunk_text" },
                                { "sourceOutput": "improvement_focus", "targetInput": "improvement_focus" }
                            ]
                        }
                    },
                    # Additional connections would be added here
                    # ...
                    # The complete connection configuration from the original script
                ]
            }
        }
        
        # Save flow definition to file
        with open(f"{self.config.FLOW_TEMPLATES_DIR}/{flow_name}.json", 'w') as f:
            json.dump(flow_def, f, indent=4)
            
        logger.info(f"Improvement flow template generated: {flow_name}")
    
    def _generate_research_flow(self, flow_name: str, role_arn: str) -> None:
        """Generate flow JSON for research flow."""
        # Get model IDs
        research_specialist_model = self.config.get_config_value('models.research_specialist', self.config.default_model)
        integration_editor_model = self.config.get_config_value('models.integration_editor', self.config.default_model)
        
        # Create flow definition
        flow_def = {
            "name": flow_name,
            "description": "Research flow for novel editing system",
            "executionRoleArn": role_arn,
            "definition": {
                "nodes": [
                    # Input node
                    {
                        "type": "Input",
                        "name": "FlowInputNode",
                        "outputs": [
                            { "name": "manuscript_id", "type": "String" },
                            { "name": "chunk_id", "type": "String" },
                            { "name": "chunk_text", "type": "String" },
                            { "name": "research_topic", "type": "String" }
                        ]
                    },
                    # Research Specialist node
                    {
                        "type": "Prompt",
                        "name": "ResearchSpecialistNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": research_specialist_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Research Specialist. Conduct research on the following topic for manuscript '{{manuscript_id}}' (Chunk ID: {{chunk_id}}):\n\nResearch Topic: {{research_topic}}\n\nProvide a detailed research report with relevant findings and sources."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "chunk_id", "type": "String", "expression": "$.chunk_id" },
                            { "name": "research_topic", "type": "String", "expression": "$.research_topic" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Integration Editor node
                    {
                        "type": "Prompt",
                        "name": "IntegrationEditorNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": integration_editor_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Integration Editor. Integrate the research findings into the manuscript '{{manuscript_id}}' (Chunk ID: {{chunk_id}}):\n\nResearch Findings: {{ResearchSpecialistNode.modelCompletion}}\n\nProvide a detailed integration plan to incorporate the research findings into the manuscript."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "chunk_id", "type": "String", "expression": "$.chunk_id" },
                            { "name": "research_findings", "type": "String", "expression": "$.ResearchSpecialistNode.modelCompletion" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Output node
                    {
                        "type": "Output",
                        "name": "FlowOutputNode",
                        "inputs": [
                            { "name": "integration_plan", "type": "String", "expression": "$.IntegrationEditorNode.modelCompletion" }
                        ]
                    }
                ],
                "connections": [
                    # Connections (Input → nodes)
                    {
                        "name": "Input_to_ResearchSpecialist",
                        "source": "FlowInputNode",
                        "target": "ResearchSpecialistNode",
                        "type": "Data",
                        "configuration": {
                            "data": [
                                { "sourceOutput": "manuscript_id", "targetInput": "manuscript_id" },
                                { "sourceOutput": "chunk_id", "targetInput": "chunk_id" },
                                { "sourceOutput": "research_topic", "targetInput": "research_topic" }
                            ]
                        }
                    },
                    # Additional connections would be added here
                    # ...
                    # The complete connection configuration from the original script
                ]
            }
        }
        
        # Save flow definition to file
        with open(f"{self.config.FLOW_TEMPLATES_DIR}/{flow_name}.json", 'w') as f:
            json.dump(flow_def, f, indent=4)
            
        logger.info(f"Research flow template generated: {flow_name}")
    
    def _generate_finalization_flow(self, flow_name: str, role_arn: str) -> None:
        """Generate flow JSON for final review flow."""
        # Get model IDs
        final_polish_editor_model = self.config.get_config_value('models.final_polish_editor', self.config.default_model)
        executive_model = self.config.get_config_value('models.executive_editor', self.config.default_model)
        
        # Create flow definition
        flow_def = {
            "name": flow_name,
            "description": "Final review flow for novel editing system",
            "executionRoleArn": role_arn,
            "definition": {
                "nodes": [
                    # Input node
                    {
                        "type": "Input",
                        "name": "FlowInputNode",
                        "outputs": [
                            { "name": "manuscript_id", "type": "String" },
                            { "name": "title", "type": "String" },
                            { "name": "final_text", "type": "String" },
                            { "name": "previous_assessment", "type": "String" }
                        ]
                    },
                    # Final Polish Editor node
                    {
                        "type": "Prompt",
                        "name": "FinalPolishEditorNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": final_polish_editor_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Final Polish Editor. Review the final text of manuscript '{{title}}' (ID: {{manuscript_id}}):\n\n{{final_text}}\n\nFocus on making final adjustments to ensure the text is polished and ready for publication. Address any remaining issues from the previous assessment: {{previous_assessment}}."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "title", "type": "String", "expression": "$.title" },
                            { "name": "final_text", "type": "String", "expression": "$.final_text" },
                            { "name": "previous_assessment", "type": "String", "expression": "$.previous_assessment" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Executive Editor node
                    {
                        "type": "Prompt",
                        "name": "ExecutiveEditorNode",
                        "configuration": {
                            "prompt": {
                                "sourceConfiguration": {
                                    "inline": {
                                        "modelId": executive_model,
                                        "templateType": "TEXT",
                                        "inferenceConfiguration": {
                                            "text": { "temperature": 0.2, "topP": 0.9 }
                                        },
                                        "templateConfiguration": {
                                            "text": {
                                                "text": "You are the Executive Editor. Provide an executive summary for the final text of manuscript '{{title}}' (ID: {{manuscript_id}}):\n\n{{FinalPolishEditorNode.modelCompletion}}\n\nSummarize the key strengths and improvements made to the manuscript, and provide a final assessment of its readiness for publication."
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        "inputs": [
                            { "name": "manuscript_id", "type": "String", "expression": "$.manuscript_id" },
                            { "name": "title", "type": "String", "expression": "$.title" },
                            { "name": "final_text", "type": "String", "expression": "$.FinalPolishEditorNode.modelCompletion" }
                        ],
                        "outputs": [{ "name": "modelCompletion", "type": "String" }]
                    },
                    # Output node
                    {
                        "type": "Output",
                        "name": "FlowOutputNode",
                        "inputs": [
                            { "name": "final_polished_text", "type": "String", "expression": "$.FinalPolishEditorNode.modelCompletion" },
                            { "name": "executive_summary", "type": "String", "expression": "$.ExecutiveEditorNode.modelCompletion" }
                        ]
                    }
                ],
                "connections": [
                    # Connections (Input → nodes)
                    {
                        "name": "Input_to_FinalPolishEditor",
                        "source": "FlowInputNode",
                        "target": "FinalPolishEditorNode",
                        "type": "Data",
                        "configuration": {
                            "data": [
                                { "sourceOutput": "manuscript_id", "targetInput": "manuscript_id" },
                                { "sourceOutput": "title", "targetInput": "title" },
                                { "sourceOutput": "final_text", "targetInput": "final_text" },
                                { "sourceOutput": "previous_assessment", "targetInput": "previous_assessment" }
                            ]
                        }
                    },
                    # Additional connections would be added here
                    # ...
                    # The complete connection configuration from the original script
                ]
            }
        }
        
        # Save flow definition to file
        with open(f"{self.config.FLOW_TEMPLATES_DIR}/{flow_name}.json", 'w') as f:
            json.dump(flow_def, f, indent=4)
            
        logger.info(f"Finalization flow template generated: {flow_name}")
