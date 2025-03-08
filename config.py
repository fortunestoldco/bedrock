import os
import json
import logging
from typing import Dict, Any, Optional, List

def configure_logging():
    """Configure application logging."""
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        handlers=[
            logging.StreamHandler(),
            logging.FileHandler('storybook.log')
        ]
    )

class storybookConfig:
    """Configuration manager for storybook."""
    
    def __init__(self):
        """Initialize configuration."""
        # Define paths
        self.CONFIG_FILE = "./config.json"
        self.FLOW_TEMPLATES_DIR = "./flow_templates"
        self.FLOWS_LIST_FILE = "./flows_list.json"
        self.TEMP_DIR = "./temp"
        self.MANUSCRIPT_DIR = "./manuscripts"
        self.CHUNKS_DIR = "./chunks"
        self.RESEARCH_DIR = "./research"
        
        # AWS defaults
        self.DEFAULT_REGION = "us-west-2"
        self.DEFAULT_MODEL = "anthropic.claude-3-sonnet-20240229-v1:0"
        self.DEFAULT_ROLE_NAME = "storybookRole"
        self.DEFAULT_TABLE_PREFIX = "storybook"
        
        # Chunk size defaults
        self.DEFAULT_CHUNK_SIZE = 8000
        self.DEFAULT_OVERLAP = 500
        
        # Create required directories
        for directory in [self.TEMP_DIR, self.FLOW_TEMPLATES_DIR, 
                         self.MANUSCRIPT_DIR, self.CHUNKS_DIR, self.RESEARCH_DIR]:
            os.makedirs(directory, exist_ok=True)
        
        # Initialize configuration
        self._initialize_config()
        self._initialize_flows_list()
        
        # Load configuration values
        self._load_config()
    
    def _initialize_config(self) -> None:
        """Initialize configuration file if it doesn't exist."""
        if not os.path.isfile(self.CONFIG_FILE):
            logging.info(f"Initializing configuration file: {self.CONFIG_FILE}")
            
            default_config = {
                "aws_region": self.DEFAULT_REGION,
                "aws_profile": "default",
                "default_model": self.DEFAULT_MODEL,
                "role_name": self.DEFAULT_ROLE_NAME,
                "table_prefix": self.DEFAULT_TABLE_PREFIX,
                "chunk_size": self.DEFAULT_CHUNK_SIZE,
                "chunk_overlap": self.DEFAULT_OVERLAP,
                "quality_thresholds": {
                    "style_consistency": 7,
                    "narrative_coherence": 8,
                    "character_consistency": 7,
                    "pacing": 7,
                    "dialogue_quality": 8,
                    "literary_quality": 8,
                    "engagement_potential": 8,
                    "market_appeal": 7
                },
                "models": {
                    "executive_editor": self.DEFAULT_MODEL,
                    "content_assessor": self.DEFAULT_MODEL,
                    "developmental_editor": self.DEFAULT_MODEL,
                    "line_editor": self.DEFAULT_MODEL,
                    "style_specialist": self.DEFAULT_MODEL,
                    "pacing_analyst": self.DEFAULT_MODEL,
                    "dialogue_specialist": self.DEFAULT_MODEL,
                    "character_consistency_checker": self.DEFAULT_MODEL,
                    "narrative_coherence_expert": self.DEFAULT_MODEL,
                    "plot_structure_analyst": self.DEFAULT_MODEL,
                    "worldbuilding_evaluator": self.DEFAULT_MODEL,
                    "audience_engagement_analyst": self.DEFAULT_MODEL,
                    "conflict_progression_analyst": self.DEFAULT_MODEL,
                    "emotional_arc_evaluator": self.DEFAULT_MODEL,
                    "voice_consistency_examiner": self.DEFAULT_MODEL,
                    "research_verifier": self.DEFAULT_MODEL,
                    "market_trends_analyst": self.DEFAULT_MODEL,
                    "language_refiner": self.DEFAULT_MODEL,
                    "genre_specialist": self.DEFAULT_MODEL,
                    "continuity_checker": self.DEFAULT_MODEL,
                    "proofreader": self.DEFAULT_MODEL,
                    "text_improver": self.DEFAULT_MODEL,
                    "research_specialist": self.DEFAULT_MODEL,
                    "integration_editor": self.DEFAULT_MODEL,
                    "final_polish_editor": self.DEFAULT_MODEL
                },
                "prompt_templates": {},
                "knowledge_bases": {},
                "processing_settings": {
                    "web_search_enabled": True,
                    "context_synthesis": True,
                    "nlp_analysis": True,
                    "progressive_refinement": True,
                    "auto_research": True
                }
            }
            
            os.makedirs(os.path.dirname(self.CONFIG_FILE), exist_ok=True)
            with open(self.CONFIG_FILE, 'w') as f:
                json.dump(default_config, f, indent=4)
            
            logging.info(f"Configuration file created at {self.CONFIG_FILE}")
    
    def _initialize_flows_list(self) -> None:
        """Initialize flows list file if it doesn't exist."""
        if not os.path.isfile(self.FLOWS_LIST_FILE):
            logging.info(f"Creating flows list file: {self.FLOWS_LIST_FILE}")
            
            with open(self.FLOWS_LIST_FILE, 'w') as f:
                json.dump({"flows": []}, f, indent=4)
            
            logging.info(f"Flows list file created at {self.FLOWS_LIST_FILE}")
    
    def _load_config(self) -> None:
        """Load configuration values."""
        with open(self.CONFIG_FILE, 'r') as f:
            config = json.load(f)
            
        # Load main configuration values
        self.aws_region = config.get('aws_region', self.DEFAULT_REGION)
        self.aws_profile = config.get('aws_profile', 'default')
        self.default_model = config.get('default_model', self.DEFAULT_MODEL)
        self.role_name = config.get('role_name', self.DEFAULT_ROLE_NAME)
        self.table_prefix = config.get('table_prefix', self.DEFAULT_TABLE_PREFIX)
        self.chunk_size = config.get('chunk_size', self.DEFAULT_CHUNK_SIZE)
        self.chunk_overlap = config.get('chunk_overlap', self.DEFAULT_OVERLAP)
        
        # Store the full config for reference
        self._config = config
    
    def get_config(self) -> Dict[str, Any]:
        """Get the full configuration."""
        with open(self.CONFIG_FILE, 'r') as f:
            return json.load(f)
    
    def get_config_value(self, key: str, default: Any = None) -> Any:
        """Get a specific configuration value using dot notation."""
        keys = key.split('.')
        value = self._config
        
        for k in keys:
            if isinstance(value, dict) and k in value:
                value = value[k]
            else:
                return default
        
        return value
    
    def get_config_section(self, section: str) -> Dict[str, Any]:
        """Get a specific configuration section."""
        with open(self.CONFIG_FILE, 'r') as f:
            config = json.load(f)
        
        return config.get(section, {})
    
    def update_config(self, key: str, value: Any) -> None:
        """Update a specific configuration value using dot notation."""
        with open(self.CONFIG_FILE, 'r') as f:
            config = json.load(f)
        
        keys = key.split('.')
        current = config
        
        # Navigate to the right level
        for k in keys[:-1]:
            if k not in current:
                current[k] = {}
            current = current[k]
        
        # Update the value
        current[keys[-1]] = value
        
        # Save the updated config
        with open(self.CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=4)
        
        # Reload config
        self._load_config()
    
    def update_config_section(self, section: str, data: Dict[str, Any]) -> None:
        """Update an entire configuration section."""
        with open(self.CONFIG_FILE, 'r') as f:
            config = json.load(f)
        
        config[section] = data
        
        with open(self.CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=4)
        
        # Reload config
        self._load_config()
