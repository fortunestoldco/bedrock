import os
import sys
import json
import argparse
import boto3
import logging
from typing import Dict, List, Any, Optional, Tuple
from pathlib import Path

# Import modules
from config import StorybookConfig, configure_logging
from iam import IAMManager
from dynamo import DynamoDBManager
from flows import FlowManager
from manuscript import ManuscriptProcessor
from research import ResearchManager

# Setup logging
configure_logging()
logger = logging.getLogger("storybook")

class Storybook:
    """Main storybook application class."""
    
    def __init__(self):
        """Initialize storybook application."""
        self.config = StorybookConfig()
        self.iam_manager = IAMManager(self.config)
        self.dynamo_manager = DynamoDBManager(self.config)
        self.flow_manager = FlowManager(self.config, self.iam_manager)
        self.manuscript_processor = ManuscriptProcessor(self.config)
        self.research_manager = ResearchManager(self.config)
        
        # Create required directories
        for directory in [
            self.config.TEMP_DIR, 
            self.config.FLOW_TEMPLATES_DIR, 
            self.config.MANUSCRIPT_DIR,
            self.config.CHUNKS_DIR,
            self.config.RESEARCH_DIR
        ]:
            os.makedirs(directory, exist_ok=True)
    
    def create_deployment(self) -> None:
        """Create a new Novel Editing deployment."""
        print("\n=== Create New Novel Editing Deployment ===")
        
        # Validate AWS configuration
        self._check_aws_configuration()
        
        # Get project details
        project_name_raw = input("Enter project name: ")
        if not project_name_raw:
            logger.error("Project name cannot be empty")
            return
        
        # Sanitize project name (lowercase, no spaces, alphanumeric and hyphens only)
        project_name = ''.join(c for c in project_name_raw.lower() if c.isalnum() or c == '-')
        project_name = project_name.replace(' ', '-')
        
        # Check if project already exists
        if self.flow_manager.project_exists(project_name):
            logger.error(f"A project with name '{project_name}' already exists")
            return
        
        # Get manuscript file
        manuscript_file = input("Enter path to manuscript file: ")
        if not os.path.isfile(manuscript_file):
            logger.error(f"Manuscript file not found: {manuscript_file}")
            return
        
        # Get manuscript title
        manuscript_title = input("Enter manuscript title: ")
        if not manuscript_title:
            logger.error("Manuscript title cannot be empty")
            return
        
        # Setup IAM role for Bedrock Flows
        logger.info("Setting up IAM role...")
        role_arn = self.iam_manager.ensure_role_exists()
        if not role_arn:
            logger.error("Failed to create or get IAM role")
            return
        
        # Generate flow templates
        logger.info("Generating flow templates...")
        self.flow_manager.generate_templates(project_name, role_arn)
        
        # Create flows in AWS Bedrock
        logger.info("Creating flows in AWS Bedrock...")
        flow_info = self.flow_manager.create_flows(project_name)
        if not flow_info:
            logger.error("Failed to create flows")
            return
        
        # Create DynamoDB tables
        logger.info("Creating DynamoDB tables...")
        if not self.dynamo_manager.initialize_tables(project_name):
            logger.error("Failed to create DynamoDB tables")
            return
        
        # Process manuscript (chunk and assess)
        logger.info("Processing manuscript...")
        if not self.manuscript_processor.process_manuscript(project_name, manuscript_file, manuscript_title):
            logger.error("Failed to process manuscript")
            return
        
        # Save project in flows list
        self.flow_manager.add_project_to_list(project_name)
        
        # Save flow details to project configuration file
        logger.info("Saving project configuration...")
        self.flow_manager.save_project_config(project_name, manuscript_title, flow_info)
        
        print(f"\nDeployment completed successfully!")
        print(f"Project configuration saved to {project_name}_config.json")
        print("\nTo improve your manuscript:")
        print("  1. Use the 'Process Manuscript' option from the main menu")
        print("  2. Select this project to start editing")
        print("  3. The system will process chunks in parallel and provide comprehensive improvements")
    
    def process_manuscript(self) -> None:
        """Process an existing manuscript."""
        print("\n=== Process Existing Manuscript ===")
        
        # Get list of projects
        projects = self.flow_manager.list_projects()
        if not projects:
            print("No existing deployments found.")
            return
        
        # Display projects
        print("Existing deployments:")
        for i, project in enumerate(projects, 1):
            print(f"{i}) {project}")
        
        # Select a project
        try:
            selection = int(input("Enter the number of the deployment to process (or 0 to cancel): "))
            if selection == 0 or selection > len(projects):
                print("Operation cancelled.")
                return
        except ValueError:
            print("Invalid selection.")
            return
        
        selected_project = projects[selection-1]
        
        # Get project status
        project_status = self.dynamo_manager.get_project_status(selected_project)
        if not project_status:
            logger.error(f"Could not retrieve project status for {selected_project}")
            return
        
        current_phase = project_status.get('current_phase', 'unknown')
        chunks_processed = int(project_status.get('chunks_processed', 0))
        total_chunks = int(project_status.get('total_chunks', 0))
        
        print(f"Project status: Phase={current_phase}, Progress={chunks_processed}/{total_chunks} chunks")
        
        # Display options based on current phase
        print("Available actions:")
        
        if current_phase == "assessment":
            print("1) Process manuscript chunks")
            print("0) Cancel")
            
            action = input("Enter your choice: ")
            
            if action == "1":
                self.manuscript_processor.process_chunks(selected_project)
            elif action == "0":
                print("Operation cancelled.")
            else:
                print("Invalid choice.")
                
        elif current_phase in ["improvement", "in_progress"]:
            print("1) Continue processing manuscript chunks")
            print("2) Finalize manuscript")
            print("0) Cancel")
            
            action = input("Enter your choice: ")
            
            if action == "1":
                self.manuscript_processor.process_chunks(selected_project)
            elif action == "2":
                self.manuscript_processor.finalize_manuscript(selected_project)
            elif action == "0":
                print("Operation cancelled.")
            else:
                print("Invalid choice.")
                
        elif current_phase == "finalization":
            print("1) Finalize manuscript")
            print("0) Cancel")
            
            action = input("Enter your choice: ")
            
            if action == "1":
                self.manuscript_processor.finalize_manuscript(selected_project)
            elif action == "0":
                print("Operation cancelled.")
            else:
                print("Invalid choice.")
                
        elif current_phase == "complete":
            print("This project is complete. Manuscript has been finalized.")
            print("1) View executive summary")
            print("0) Cancel")
            
            action = input("Enter your choice: ")
            
            if action == "1":
                summary_file = os.path.join(self.config.MANUSCRIPT_DIR, f"{selected_project}_executive_summary.txt")
                if os.path.isfile(summary_file):
                    with open(summary_file, 'r') as f:
                        print("\n" + f.read())
                else:
                    print(f"Executive summary not found: {summary_file}")
            elif action == "0":
                print("Operation cancelled.")
            else:
                print("Invalid choice.")
                
        else:
            print(f"Unknown project phase: {current_phase}")
    
    def conduct_research(self) -> None:
        """Conduct research for a manuscript."""
        print("\n=== Conduct Research ===")
        
        # Get list of projects
        projects = self.flow_manager.list_projects()
        if not projects:
            print("No existing deployments found.")
            return
        
        # Display projects
        print("Existing deployments:")
        for i, project in enumerate(projects, 1):
            print(f"{i}) {project}")
        
        # Select a project
        try:
            selection = int(input("Enter the number of the deployment for research (or 0 to cancel): "))
            if selection == 0 or selection > len(projects):
                print("Operation cancelled.")
                return
        except ValueError:
            print("Invalid selection.")
            return
        
        selected_project = projects[selection-1]
        
        # Check if project config exists
        if not os.path.isfile(f"{selected_project}_config.json"):
            logger.error(f"Project configuration file not found: {selected_project}_config.json")
            return
        
        # Get research topic
        research_topic = input("Enter research topic: ")
        if not research_topic:
            logger.error("Research topic cannot be empty")
            return
        
        # Choose research input method
        print("Choose research input method:")
        print("1) Provide specific chunk ID")
        print("2) Provide sample text")
        print("0) Cancel")
        
        input_method = input("Enter your choice: ")
        
        chunk_id = ""
        chunk_text = ""
        
        if input_method == "1":
            chunk_id = input("Enter chunk ID (e.g., chunk_0001): ")
            chunk_text = self.manuscript_processor.get_chunk_text(selected_project, chunk_id)
            if not chunk_text:
                logger.error(f"Could not retrieve text for chunk {chunk_id}")
                return
                
        elif input_method == "2":
            print("Enter sample text (type 'END' on a new line when finished):")
            chunk_id = "custom_sample"
            lines = []
            
            while True:
                line = input()
                if line == "END":
                    break
                lines.append(line)
            
            chunk_text = "\n".join(lines)
            
        elif input_method == "0":
            print("Operation cancelled.")
            return
            
        else:
            print("Invalid choice.")
            return
        
        # Conduct research
        self.research_manager.conduct_research(selected_project, research_topic, chunk_id, chunk_text)
    
    def remove_deployment(self) -> None:
        """Remove a deployment."""
        print("\n=== Remove Deployment ===")
        
        # Get list of projects
        projects = self.flow_manager.list_projects()
        if not projects:
            print("No existing deployments found.")
            return
        
        # Display projects
        print("Existing deployments:")
        for i, project in enumerate(projects, 1):
            print(f"{i}) {project}")
        
        # Select a project
        try:
            selection = int(input("Enter the number of the deployment to remove (or 0 to cancel): "))
            if selection == 0 or selection > len(projects):
                print("Operation cancelled.")
                return
        except ValueError:
            print("Invalid selection.")
            return
        
        selected_project = projects[selection-1]
        
        # Confirm deletion
        confirm = input(f"Are you sure you want to delete deployment '{selected_project}'? (y/n): ")
        if confirm.lower() != 'y':
            print("Operation cancelled.")
            return
        
        # Delete deployment
        self.flow_manager.delete_flows(selected_project)
        self.dynamo_manager.delete_tables(selected_project)
        
        # Remove files
        print("Cleaning up project files...")
        
        # Remove template files
        for file in Path(self.config.FLOW_TEMPLATES_DIR).glob(f"{selected_project}-*.json"):
            file.unlink(missing_ok=True)
        
        # Remove chunks
        for file in Path(self.config.CHUNKS_DIR).glob(f"{selected_project}*"):
            if file.is_dir():
                import shutil
                shutil.rmtree(file, ignore_errors=True)
            else:
                file.unlink(missing_ok=True)
        
        # Remove manuscripts
        for file in Path(self.config.MANUSCRIPT_DIR).glob(f"{selected_project}*.*"):
            file.unlink(missing_ok=True)
        
        # Remove research
        for file in Path(self.config.RESEARCH_DIR).glob(f"{selected_project}*.*"):
            file.unlink(missing_ok=True)
        
        # Remove project config file
        project_config = Path(f"{selected_project}_config.json")
        if project_config.exists():
            project_config.unlink()
        
        # Update flows list
        self.flow_manager.remove_project_from_list(selected_project)
        
        print(f"Deployment '{selected_project}' successfully removed.")
    
    def configure_aws(self) -> None:
        """Configure AWS settings."""
        print("\n=== Configure AWS Settings ===")
        
        while True:
            print("\nAWS configuration options:")
            print("1) Configure AWS credentials")
            print("2) Change AWS region")
            print("3) Change AWS profile")
            print("4) Change IAM role")
            print("5) Change DynamoDB table prefix")
            print("0) Return to main menu")
            
            aws_choice = input("Enter your choice: ")
            
            if aws_choice == "1":
                os.system("aws configure")
                print("AWS credentials updated.")
                
            elif aws_choice == "2":
                self._change_aws_region()
                
            elif aws_choice == "3":
                self._change_aws_profile()
                
            elif aws_choice == "4":
                self._change_iam_role()
                
            elif aws_choice == "5":
                self._change_table_prefix()
                
            elif aws_choice == "0":
                print("Returning to main menu...")
                break
                
            else:
                print("Invalid choice.")
    
    def modify_configuration(self) -> None:
        """Modify configuration settings."""
        print("\n=== Modify Configuration ===")
        
        while True:
            print("\nConfiguration options:")
            print("1) Change default model")
            print("2) Modify agent-specific models")
            print("3) Edit quality thresholds")
            print("4) Edit chunking settings")
            print("5) Toggle features (web search, etc.)")
            print("0) Return to main menu")
            
            config_choice = input("Enter your choice: ")
            
            if config_choice == "1":
                self._change_default_model()
                
            elif config_choice == "2":
                self._modify_agent_models()
                
            elif config_choice == "3":
                self._edit_quality_thresholds()
                
            elif config_choice == "4":
                self._edit_chunking_settings()
                
            elif config_choice == "5":
                self._toggle_features()
                
            elif config_choice == "0":
                print("Returning to main menu...")
                break
                
            else:
                print("Invalid choice.")
    
    def _check_aws_configuration(self) -> bool:
        """Check if AWS CLI is properly configured."""
        print("Checking AWS configuration...")
        
        try:
            session = boto3.Session(
                region_name=self.config.aws_region,
                profile_name=self.config.aws_profile
            )
            sts = session.client('sts')
            sts.get_caller_identity()
            print("AWS configuration is valid.")
            return True
        except Exception as e:
            print(f"Error: AWS CLI is not properly configured.\nError: {str(e)}")
            print("Please configure AWS CLI with 'aws configure' command.")
            print("Alternatively, select option 6) AWS Configuration from the main menu.")
            return False
    
    def _change_aws_region(self) -> None:
        """Change the default AWS region."""
        print("\n=== Change Default AWS Region ===")
        
        print(f"Current region: {self.config.aws_region}")
        
        # List available regions
        print("Available regions:")
        regions = [
            "us-east-1", "us-east-2", "us-west-1", "us-west-2",
            "ap-south-1", "ap-northeast-1", "ap-northeast-2",
            "ap-southeast-1", "ap-southeast-2", "ca-central-1",
            "eu-central-1", "eu-west-1", "eu-west-2", "eu-west-3",
            "eu-north-1", "sa-east-1"
        ]
        
        region_names = {
            "us-east-1": "US East (N. Virginia)",
            "us-east-2": "US East (Ohio)",
            "us-west-1": "US West (N. California)",
            "us-west-2": "US West (Oregon)",
            "ap-south-1": "Asia Pacific (Mumbai)",
            "ap-northeast-1": "Asia Pacific (Tokyo)",
            "ap-northeast-2": "Asia Pacific (Seoul)",
            "ap-southeast-1": "Asia Pacific (Singapore)",
            "ap-southeast-2": "Asia Pacific (Sydney)",
            "ca-central-1": "Canada (Central)",
            "eu-central-1": "EU (Frankfurt)",
            "eu-west-1": "EU (Ireland)",
            "eu-west-2": "EU (London)",
            "eu-west-3": "EU (Paris)",
            "eu-north-1": "EU (Stockholm)",
            "sa-east-1": "South America (São Paulo)"
        }
        
        for region in regions:
            print(f"{region}) {region_names.get(region, region)}")
        
        new_region = input("Enter new AWS region: ")
        
        if not new_region:
            print("Operation cancelled.")
            return
        
        # Update config
        self.config.update_config('aws_region', new_region)
        print(f"Default AWS region updated to {new_region}.")
    
    def _change_aws_profile(self) -> None:
        """Change the AWS profile."""
        print("\n=== Change AWS Profile ===")
        
        print(f"Current AWS profile: {self.config.aws_profile}")
        
        # List available profiles
        print("Available profiles:")
        try:
            profiles = boto3.Session().available_profiles
            for i, profile in enumerate(profiles, 1):
                print(f"{i}) {profile}")
        except Exception:
            print("No profiles found")
        
        new_profile = input("Enter new AWS profile: ")
        
        if not new_profile:
            print("Operation cancelled.")
            return
        
        # Update config
        self.config.update_config('aws_profile', new_profile)
        print(f"AWS profile updated to {new_profile}.")
    
    def _change_iam_role(self) -> None:
        """Change the IAM role name."""
        print("\n=== Change IAM Role ===")
        
        print(f"Current IAM role: {self.config.role_name}")
        
        new_role = input("Enter new IAM role name: ")
        
        if not new_role:
            print("Operation cancelled.")
            return
        
        # Check if role exists
        session = boto3.Session(
            region_name=self.config.aws_region,
            profile_name=self.config.aws_profile
        )
        iam = session.client('iam')
        
        try:
            iam.get_role(RoleName=new_role)
            role_exists = True
        except Exception:
            role_exists = False
            
        if not role_exists:
            print(f"Role '{new_role}' does not exist.")
            create_role = input("Do you want to create it? (y/n): ")
            
            if create_role.lower() == 'y':
                # Update config
                self.config.update_config('role_name', new_role)
                
                # Create the role
                self.iam_manager.ensure_role_exists()
            else:
                print("Operation cancelled.")
                return
        else:
            # Update config
            self.config.update_config('role_name', new_role)
            print(f"IAM role updated to {new_role}.")
    
    def _change_table_prefix(self) -> None:
        """Change the DynamoDB table prefix."""
        print("\n=== Change DynamoDB Table Prefix ===")
        
        print(f"Current table prefix: {self.config.table_prefix}")
        
        new_prefix = input("Enter new table prefix: ")
        
        if not new_prefix:
            print("Operation cancelled.")
            return
        
        # Update config
        self.config.update_config('table_prefix', new_prefix)
        print(f"DynamoDB table prefix updated to {new_prefix}.")
        print("This change will only affect new deployments.")
    
    def _change_default_model(self) -> None:
        """Change the default model."""
        print("\n=== Change Default Model ===")
        
        print(f"Current default model: {self.config.default_model}")
        
        # Try to fetch available models
        try:
            session = boto3.Session(
                region_name=self.config.aws_region,
                profile_name=self.config.aws_profile
            )
            bedrock = session.client('bedrock')
            response = bedrock.list_foundation_models()
            
            print("Available models:")
            for model in response.get('modelSummaries', []):
                model_id = model.get('modelId', '')
                print(f"{model_id}")
                
        except Exception:
            print("Failed to fetch models. Using built-in list.")
            print("Available models:")
            print("anthropic.claude-3-opus-20240229-v1:0 (Anthropic Claude 3 Opus)")
            print("anthropic.claude-3-sonnet-20240229-v1:0 (Anthropic Claude 3 Sonnet)")
            print("anthropic.claude-3-haiku-20240307-v1:0 (Anthropic Claude 3 Haiku)")
            print("amazon.titan-text-express-v1 (Amazon Titan Text Express)")
            print("meta.llama3-70b-instruct-v1:0 (Meta Llama 3 70B Instruct)")
            print("meta.llama3-8b-instruct-v1:0 (Meta Llama 3 8B Instruct)")
        
        new_model = input("Enter new default model ID: ")
        
        if not new_model:
            print("Operation cancelled.")
            return
        
        # Update config
        self.config.update_config('default_model', new_model)
        
        # Ask if this should apply to all agents
        apply_all = input("Apply this model to all agents? (y/n): ")
        
        if apply_all.lower() == 'y':
            models = self.config.get_config_section('models')
            
            for agent in models:
                self.config.update_config(f'models.{agent}', new_model)
            
            print(f"Applied {new_model} to all agents.")
        
        print(f"Default model updated to {new_model}.")
        print("You will need to regenerate flows for changes to take effect.")
    
    def _modify_agent_models(self) -> None:
        """Modify agent-specific models."""
        print("\n=== Modify Agent Models ===")
        
        # List agents and their models
        models = self.config.get_config_section('models')
        
        print("Current agent models:")
        agents = sorted(models.keys())
        for i, agent in enumerate(agents, 1):
            print(f"{i}) {agent}: {models[agent]}")
        
        try:
            agent_num = int(input("Enter agent number to modify (or 0 for all agents): "))
            
            if not agent_num:
                print("Operation cancelled.")
                return
            
            if agent_num == 0:
                # Update all agents
                self._change_default_model()
                return
            
            if agent_num > len(agents):
                print("Invalid agent number.")
                return
                
        except ValueError:
            print("Invalid input. Must be a number.")
            return
        
        agent_name = agents[agent_num-1]
        current_model = models[agent_name]
        
        print(f"Current model for {agent_name}: {current_model}")
        
        # List some common models
        print("Available models (sample):")
        print("anthropic.claude-3-opus-20240229-v1:0 (Anthropic Claude 3 Opus)")
        print("anthropic.claude-3-sonnet-20240229-v1:0 (Anthropic Claude 3 Sonnet)")
        print("anthropic.claude-3-haiku-20240307-v1:0 (Anthropic Claude 3 Haiku)")
        print("amazon.titan-text-express-v1 (Amazon Titan Text Express)")
        print("meta.llama3-70b-instruct-v1:0 (Meta Llama 3 70B Instruct)")
        print("meta.llama3-8b-instruct-v1:0 (Meta Llama 3 8B Instruct)")
        
        new_model = input(f"Enter new model ID for {agent_name}: ")
        
        if not new_model:
            print("Operation cancelled.")
            return
        
        # Update specific agent
        self.config.update_config(f'models.{agent_name}', new_model)
        
        print(f"Updated {agent_name} to use {new_model}.")
        print("You will need to regenerate flows for changes to take effect.")
    
    def _edit_quality_thresholds(self) -> None:
        """Edit quality thresholds."""
        print("\n=== Edit Quality Thresholds ===")
        
        # List current thresholds
        thresholds = self.config.get_config_section('quality_thresholds')
        
        print("Current quality thresholds:")
        for i, (key, value) in enumerate(sorted(thresholds.items()), 1):
            print(f"{i}) {key}: {value}")
        
        # Store in temp file
        temp_file = os.path.join(self.config.TEMP_DIR, "quality_thresholds.json")
        with open(temp_file, 'w') as f:
            json.dump(thresholds, f, indent=2)
        
        # Get editor (use EDITOR env var or default to nano)
        editor = os.environ.get('EDITOR', 'nano')
        
        print(f"Opening editor to update quality thresholds...")
        os.system(f"{editor} {temp_file}")
        
        # Read updated thresholds
        try:
            with open(temp_file, 'r') as f:
                updated_thresholds = json.load(f)
            
            # Update config
            self.config.update_config_section('quality_thresholds', updated_thresholds)
            print("Quality thresholds updated.")
            
        except json.JSONDecodeError:
            print("Invalid JSON. Changes not saved.")
    
    def _edit_chunking_settings(self) -> None:
        """Edit chunking settings."""
        print("\n=== Edit Chunking Settings ===")
        
        print("Current chunking settings:")
        print(f"1) Chunk size: {self.config.chunk_size} tokens")
        print(f"2) Chunk overlap: {self.config.chunk_overlap} tokens")
        print("0) Cancel")
        
        setting_num = input("Enter setting to change: ")
        
        if setting_num == "1":
            try:
                new_size = int(input("Enter new chunk size (tokens): "))
                self.config.update_config('chunk_size', new_size)
                print(f"Chunk size updated to {new_size} tokens.")
            except ValueError:
                print("Invalid value. Must be a number.")
                
        elif setting_num == "2":
            try:
                new_overlap = int(input("Enter new chunk overlap (tokens): "))
                self.config.update_config('chunk_overlap', new_overlap)
                print(f"Chunk overlap updated to {new_overlap} tokens.")
            except ValueError:
                print("Invalid value. Must be a number.")
                
        elif setting_num == "0":
            print("Operation cancelled.")
            
        else:
            print("Invalid choice.")
    
    def _toggle_features(self) -> None:
        """Toggle processing features."""
        print("\n=== Toggle Features ===")
        
        # List current settings
        settings = self.config.get_config_section('processing_settings')
        
        print("Current feature settings:")
        features = sorted(settings.keys())
        for i, feature in enumerate(features, 1):
            print(f"{i}) {feature}: {settings[feature]}")
        
        try:
            feature_num = int(input("Enter feature number to toggle (or 0 to cancel): "))
            
            if feature_num == 0:
                print("Operation cancelled.")
                return
            
            if feature_num > len(features):
                print("Invalid feature number.")
                return
                
        except ValueError:
            print("Invalid input. Must be a number.")
            return
        
        feature_name = features[feature_num-1]
        current_value = settings[feature_name]
        
        # Toggle value
        new_value = not current_value
        
        # Update config
        self.config.update_config(f'processing_settings.{feature_name}', new_value)
        
        print(f"Feature '{feature_name}' toggled to {new_value}.")

    def run(self) -> None:
        """Run the storybook application."""
        # Clear screen and display header
        os.system('cls' if os.name == 'nt' else 'clear')
        print("=========================================")
        print("   storybook - Bedrock Novel Editor     ")
        print("=========================================")
        
        while True:
            print("\nMain Menu:")
            print("1) Create New Manuscript Project")
            print("2) Process Existing Manuscript")
            print("3) Conduct Research")
            print("4) Remove Manuscript Project")
            print("5) Modify Configuration (Models, Thresholds)")
            print("6) AWS Configuration")
            print("q) Quit")
            
            choice = input("Enter your choice: ")
            
            if choice == "1":
                self.create_deployment()
            elif choice == "2":
                self.process_manuscript()
            elif choice == "3":
                self.conduct_research()
            elif choice == "4":
                self.remove_deployment()
            elif choice == "5":
                self.modify_configuration()
            elif choice == "6":
                self.configure_aws()
            elif choice.lower() == "q":
                print("Exiting. Goodbye!")
                sys.exit(0)
            else:
                print("Invalid choice. Please try again.")


if __name__ == "__main__":
    app = Storybook()
    app.run()
