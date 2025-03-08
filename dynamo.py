import json
import logging
import time
import boto3
from botocore.exceptions import ClientError
from datetime import datetime
from typing import Dict, Any, Optional, List

logger = logging.getLogger("storybook.dynamo")

class DynamoDBManager:
    """Manages DynamoDB tables for storybook."""
    
    def __init__(self, config):
        """Initialize DynamoDB manager with configuration."""
        self.config = config
    
    def initialize_tables(self, project_name: str) -> bool:
        """Create DynamoDB tables for a project. Returns True if successful."""
        region = self.config.aws_region
        profile = self.config.aws_profile
        table_prefix = self.config.table_prefix
        
        logger.info(f"Creating DynamoDB tables for project {project_name}")
        
        session = boto3.Session(region_name=region, profile_name=profile)
        dynamodb = session.client('dynamodb')
        
        try:
            # Create project state table
            state_table = f"{table_prefix}_{project_name}_state"
            dynamodb.create_table(
                TableName=state_table,
                AttributeDefinitions=[
                    {"AttributeName": "manuscript_id", "AttributeType": "S"},
                    {"AttributeName": "chunk_id", "AttributeType": "S"}
                ],
                KeySchema=[
                    {"AttributeName": "manuscript_id", "KeyType": "HASH"},
                    {"AttributeName": "chunk_id", "KeyType": "RANGE"}
                ],
                ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
            )
            
            # Create edits table
            edits_table = f"{table_prefix}_{project_name}_edits"
            dynamodb.create_table(
                TableName=edits_table,
                AttributeDefinitions=[
                    {"AttributeName": "edit_id", "AttributeType": "S"}
                ],
                KeySchema=[
                    {"AttributeName": "edit_id", "KeyType": "HASH"}
                ],
                ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
            )
            
            # Create quality metrics table
            metrics_table = f"{table_prefix}_{project_name}_metrics"
            dynamodb.create_table(
                TableName=metrics_table,
                AttributeDefinitions=[
                    {"AttributeName": "metric_id", "AttributeType": "S"}
                ],
                KeySchema=[
                    {"AttributeName": "metric_id", "KeyType": "HASH"}
                ],
                ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
            )
            
            # Create research findings table
            research_table = f"{table_prefix}_{project_name}_research"
            dynamodb.create_table(
                TableName=research_table,
                AttributeDefinitions=[
                    {"AttributeName": "research_id", "AttributeType": "S"}
                ],
                KeySchema=[
                    {"AttributeName": "research_id", "KeyType": "HASH"}
                ],
                ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
            )
            
            logger.info("Waiting for tables to be created...")
            waiter = dynamodb.get_waiter('table_exists')
            for table in [state_table, edits_table, metrics_table, research_table]:
                waiter.wait(TableName=table)
            
            logger.info("DynamoDB tables created successfully")
            
            # Initialize project state
            logger.info("Initializing project state...")
            dynamodb_resource = session.resource('dynamodb')
            state_table_resource = dynamodb_resource.Table(state_table)
            
            state_table_resource.put_item(
                Item={
                    "manuscript_id": project_name,
                    "chunk_id": "metadata",
                    "status": "created",
                    "created_at": datetime.utcnow().isoformat(),
                    "updated_at": datetime.utcnow().isoformat(),
                    "title": "",
                    "author": "",
                    "total_chunks": 0,
                    "chunks_processed": 0,
                    "current_phase": "assessment",
                    "quality_scores": {}
                }
            )
            
            logger.info("Project state initialized successfully")
            return True
            
        except ClientError as e:
            logger.error(f"Error creating DynamoDB tables: {str(e)}")
            return False
    
    def get_project_status(self, project_name: str) -> Optional[Dict[str, Any]]:
        """Get the status of a project from DynamoDB."""
        region = self.config.aws_region
        profile = self.config.aws_profile
        table_prefix = self.config.table_prefix
        
        session = boto3.Session(region_name=region, profile_name=profile)
        dynamodb = session.resource('dynamodb')
        
        state_table = f"{table_prefix}_{project_name}_state"
        
        try:
            table = dynamodb.Table(state_table)
            response = table.get_item(
                Key={
                    "manuscript_id": project_name,
                    "chunk_id": "metadata"
                }
            )
            
            if 'Item' in response:
                return response['Item']
            else:
                logger.warning(f"No metadata found for project {project_name}")
                return None
                
        except ClientError as e:
            logger.error(f"Error getting project status: {str(e)}")
            return None
    
    def update_project_metadata(self, project_name: str, updates: Dict[str, Any]) -> bool:
        """Update project metadata in DynamoDB."""
        region = self.config.aws_region
        profile = self.config.aws_profile
        table_prefix = self.config.table_prefix
        
        session = boto3.Session(region_name=region, profile_name=profile)
        dynamodb = session.resource('dynamodb')
        
        state_table = f"{table_prefix}_{project_name}_state"
        
        try:
            table = dynamodb.Table(state_table)
            
            # Build update expression
            update_expression = "SET updated_at = :updated_at"
            expression_values = {
                ":updated_at": datetime.utcnow().isoformat()
            }
            
            for key, value in updates.items():
                update_expression += f", {key} = :{key.replace('.', '_')}"
                expression_values[f":{key.replace('.', '_')}"] = value
            
            # Update the item
            table.update_item(
                Key={
                    "manuscript_id": project_name,
                    "chunk_id": "metadata"
                },
                UpdateExpression=update_expression,
                ExpressionAttributeValues=expression_values
            )
            
            return True
            
        except ClientError as e:
            logger.error(f"Error updating project metadata: {str(e)}")
            return False
    
    def store_edit(self, project_name: str, chunk_id: str, 
                 original_text: str, improved_text: str, edit_type: str = "content") -> bool:
        """Store an edit in the edits table."""
        region = self.config.aws_region
        profile = self.config.aws_profile
        table_prefix = self.config.table_prefix
        
        session = boto3.Session(region_name=region, profile_name=profile)
        dynamodb = session.resource('dynamodb')
        
        edits_table = f"{table_prefix}_{project_name}_edits"
        
        try:
            table = dynamodb.Table(edits_table)
            
            table.put_item(
                Item={
                    "edit_id": chunk_id,
                    "manuscript_id": project_name,
                    "timestamp": datetime.utcnow().isoformat(),
                    "original_text": original_text,
                    "improved_text": improved_text,
                    "improvement_type": edit_type
                }
            )
            
            return True
            
        except ClientError as e:
            logger.error(f"Error storing edit: {str(e)}")
            return False
    
    def increment_chunks_processed(self, project_name: str) -> bool:
        """Increment the chunks_processed counter."""
        region = self.config.aws_region
        profile = self.config.aws_profile
        table_prefix = self.config.table_prefix
        
        session = boto3.Session(region_name=region, profile_name=profile)
        dynamodb = session.resource('dynamodb')
        
        state_table = f"{table_prefix}_{project_name}_state"
        
        try:
            table = dynamodb.Table(state_table)
            
            table.update_item(
                Key={
                    "manuscript_id": project_name,
                    "chunk_id": "metadata"
                },
                UpdateExpression="SET chunks_processed = chunks_processed + :val, updated_at = :updated_at",
                ExpressionAttributeValues={
                    ":val": 1,
                    ":updated_at": datetime.utcnow().isoformat()
                }
            )
            
            return True
            
        except ClientError as e:
            logger.error(f"Error incrementing chunks processed: {str(e)}")
            return False
    
    def store_research_findings(self, project_name: str, research_id: str, 
                             query: str, sources: List[Dict[str, Any]], summary: str) -> bool:
        """Store research findings in the research table."""
        region = self.config.aws_region
        profile = self.config.aws_profile
        table_prefix = self.config.table_prefix
        
        session = boto3.Session(region_name=region, profile_name=profile)
        dynamodb = session.resource('dynamodb')
        
        research_table = f"{table_prefix}_{project_name}_research"
        
        try:
            table = dynamodb.Table(research_table)
            
            table.put_item(
                Item={
                    "research_id": research_id,
                    "project_name": project_name,
                    "timestamp": datetime.utcnow().isoformat(),
                    "query": query,
                    "sources": sources,
                    "summary": summary
                }
            )
            
            return True
            
        except ClientError as e:
            logger.error(f"Error storing research findings: {str(e)}")
            return False
    
    def delete_tables(self, project_name: str) -> bool:
        """Delete all DynamoDB tables for a project."""
        region = self.config.aws_region
        profile = self.config.aws_profile
        table_prefix = self.config.table_prefix
        
        session = boto3.Session(region_name=region, profile_name=profile)
        dynamodb = session.client('dynamodb')
        
        # Get list of all tables
        try:
            response = dynamodb.list_tables()
            all_tables = response.get('TableNames', [])
            
            # Filter tables for this project
            project_tables = [table for table in all_tables 
                            if table.startswith(f"{table_prefix}_{project_name}")]
            
            if not project_tables:
                logger.info(f"No tables found for project {project_name}")
                return True
            
            # Delete each table
            for table in project_tables:
                logger.info(f"Deleting table {table}")
                dynamodb.delete_table(TableName=table)
            
            logger.info(f"All tables for project {project_name} have been deleted")
            return True
            
        except ClientError as e:
            logger.error(f"Error deleting tables: {str(e)}")
            return False
