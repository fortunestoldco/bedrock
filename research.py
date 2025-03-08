import os
import re
import json
import logging
import time
import boto3
import requests
from bs4 import BeautifulSoup
from datetime import datetime
from typing import Dict, List, Any, Optional, Tuple

logger = logging.getLogger("storybook.research")

class ResearchManager:
    """Manages research for storybook."""
    
    def __init__(self, config):
        """Initialize research manager with configuration."""
        self.config = config
        
        # Generate necessary Python scripts
        self._generate_research_script()
    
    def conduct_research(self, project_name: str, research_topic: str, 
                       chunk_id: str, chunk_text: str) -> bool:
        """Conduct research on a topic for a manuscript."""
        logger.info(f"Conducting research on '{research_topic}' for project {project_name}")
        
        # Create output directory
        os.makedirs(self.config.RESEARCH_DIR, exist_ok=True)
        
        # First perform web research
        logger.info("Performing web research...")
        search_results = self._search_web(research_topic)
        
        if "error" in search_results:
            logger.error(f"Search error: {search_results['error']}")
            return False
        
        # Extract content from each result
        sources = []
        for result in search_results.get("results", []):
            logger.info(f"Processing: {result['title']}")
            content_data = self._extract_content(result['url'])
            
            if "error" not in content_data:
                # Summarize content if needed
                content_data["content"] = self._summarize_content(content_data["content"])
                sources.append(content_data)
            else:
                logger.error(f"Error extracting content: {content_data['error']}")
        
        # Compile research data
        research_data = {
            "query": research_topic,
            "timestamp": datetime.utcnow().isoformat(),
            "sources": sources,
            "summary": f"Research on '{research_topic}' found {len(sources)} sources."
        }
        
        # Save to file
        research_id = f"{project_name}_{int(time.time())}"
        research_filename = re.sub(r'[\\/*?:"<>|]', "_", f"{project_name}_{research_topic[:30]}.json")
        research_path = os.path.join(self.config.RESEARCH_DIR, research_filename)
        
        with open(research_path, 'w', encoding='utf-8') as f:
            json.dump(research_data, f, indent=2)
        
        # Save to DynamoDB
        session = boto3.Session(
            region_name=self.config.aws_region,
            profile_name=self.config.aws_profile
        )
        dynamodb = session.resource('dynamodb')
        
        table_name = f"{self.config.table_prefix}_{project_name}_research"
        table = dynamodb.Table(table_name)
        
        try:
            table.put_item(
                Item={
                    'research_id': research_id,
                    'project_name': project_name,
                    'timestamp': datetime.utcnow().isoformat(),
                    'query': research_topic,
                    'sources': sources,
                    'summary': research_data['summary']
                }
            )
        except Exception as e:
            logger.error(f"Error saving to DynamoDB: {str(e)}")
        
        # Now use research flow to analyze and integrate findings
        logger.info("Using Bedrock flow to analyze research findings...")
        
        # Load project configuration
        project_config_file = f"{project_name}_config.json"
        
        if not os.path.isfile(project_config_file):
            logger.error(f"Project configuration file not found: {project_config_file}")
            return False
        
        with open(project_config_file, 'r') as f:
            project_config = json.load(f)
        
        # Get research flow IDs
        flows = project_config.get('flows', {})
        research_flow = flows.get('research', {})
        research_flow_id = research_flow.get('flow_id')
        research_alias_id = research_flow.get('alias_id')
        
        if not research_flow_id or not research_alias_id:
            logger.error("Research flow information missing from project config")
            return False
        
        # Prepare flow inputs
        inputs = [
            {
                "content": {
                    "manuscript_id": project_name,
                    "chunk_id": chunk_id,
                    "chunk_text": chunk_text,
                    "research_topic": research_topic
                },
                "nodeName": "FlowInputNode",
                "nodeOutputNames": ["manuscript_id", "chunk_id", "chunk_text", "research_topic"]
            }
        ]
        
        # Create session
        bedrock_agent_runtime = session.client('bedrock-agent-runtime')
        
        # Invoke flow
        try:
            response = bedrock_agent_runtime.invoke_flow(
                flowIdentifier=research_flow_id,
                flowAliasIdentifier=research_alias_id,
                inputs=inputs
            )
            
            # Extract results
            outputs = response.get('outputs', [])
            integration_plan = None
            
            for output in outputs:
                if output.get('name') == 'integration_plan':
                    integration_plan = output.get('content')
                    break
            
            if not integration_plan:
                logger.error("No integration plan found in flow output")
                return False
            
            # Save results
            results_file = os.path.join(
                self.config.RESEARCH_DIR, 
                f"{project_name}_{research_topic.replace(' ', '_')[:30]}_results.txt"
            )
            
            with open(results_file, 'w') as f:
                f.write(f"RESEARCH TOPIC: {research_topic}\n\n")
                f.write(f"INTEGRATION PLAN:\n{integration_plan}\n\n")
            
            logger.info(f"Research completed! Results saved to: {results_file}")
            return True
            
        except Exception as e:
            logger.error(f"Error invoking research flow: {str(e)}")
            return False
    
    def _search_web(self, query: str, max_results: int = 5) -> Dict[str, Any]:
        """Perform web search using a search API (DuckDuckGo)."""
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
        }
        
        try:
            # Using DuckDuckGo HTML search as a simple approach
            encoded_query = query.replace(' ', '+')
            response = requests.get(f'https://html.duckduckgo.com/html/?q={encoded_query}', headers=headers)
            
            if response.status_code != 200:
                return {"error": f"Search failed with status {response.status_code}"}
                
            soup = BeautifulSoup(response.text, 'html.parser')
            results = []
            
            # Extract search results
            for result in soup.select('.result__body')[:max_results]:
                title_elem = result.select_one('.result__title')
                link_elem = result.select_one('.result__url')
                snippet_elem = result.select_one('.result__snippet')
                
                if title_elem and link_elem:
                    title = title_elem.get_text().strip()
                    url = link_elem.get('href') if link_elem.has_attr('href') else link_elem.get_text().strip()
                    snippet = snippet_elem.get_text().strip() if snippet_elem else ""
                    
                    # Clean up URL if it's from DuckDuckGo's redirect
                    if '/d.js' in url:
                        url_match = re.search(r'uddg=([^&]+)', url)
                        if url_match:
                            url = requests.utils.unquote(url_match.group(1))
                    
                    results.append({
                        "title": title,
                        "url": url,
                        "snippet": snippet
                    })
            
            return {"results": results}
        
        except Exception as e:
            return {"error": str(e)}
    
    def _extract_content(self, url: str) -> Dict[str, Any]:
        """Extract main content from a web page."""
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
        }
        
        try:
            response = requests.get(url, headers=headers, timeout=10)
            if response.status_code != 200:
                return {"error": f"Failed to retrieve content: Status {response.status_code}"}
            
            soup = BeautifulSoup(response.text, 'html.parser')
            
            # Remove unwanted elements
            for element in soup(['script', 'style', 'nav', 'footer', 'header', 'aside']):
                element.decompose()
            
            # Extract title
            title = soup.title.string if soup.title else "Unknown Title"
            
            # Try to find main content
            main_content = soup.find('main') or soup.find('article') or soup.find('div', class_='content')
            
            if main_content:
                content = main_content.get_text(separator='\n')
            else:
                # Fallback to body content
                content = soup.get_text(separator='\n')
            
            # Clean up the content
            content = re.sub(r'\n+', '\n', content)
            content = re.sub(r'\s+', ' ', content)
            content = content.strip()
            
            return {
                "title": title,
                "content": content,
                "url": url
            }
        
        except Exception as e:
            return {"error": f"Error extracting content: {str(e)}"}
    
    def _summarize_content(self, content: str, max_length: int = 2000) -> str:
        """Truncate content to a maximum length while preserving whole sentences."""
        if len(content) <= max_length:
            return content
        
        # Find a sentence boundary near max_length
        truncated = content[:max_length]
        last_period = truncated.rfind('.')
        
        if last_period > 0:
            return content[:last_period + 1]
        else:
            return truncated
    
    def _generate_research_script(self) -> None:
        """Generate Python script for web research."""
        script_path = os.path.join(self.config.TEMP_DIR, "web_research.py")
        
        if os.path.isfile(script_path):
            return
            
        # Implementation similar to _generate_chunking_script
        # Script content would be based on the original script's web_research.py
        # ...
