import os
import re
import json
import logging
import time
import boto3
import shutil
import subprocess
import multiprocessing
import tiktoken
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple

logger = logging.getLogger("storybook.manuscript")

class ManuscriptProcessor:
    """Handles manuscript processing operations."""
    
    def __init__(self, config):
        """Initialize manuscript processor with configuration."""
        self.config = config
        
        # Generate necessary Python scripts
        self._generate_chunking_script()
        self._generate_assessment_script()
    
    def process_manuscript(self, project_name: str, manuscript_file: str, 
                         manuscript_title: str) -> bool:
        """Process manuscript through chunking and assessment."""
        # Store manuscript in manuscripts directory
        manuscript_copy = os.path.join(self.config.MANUSCRIPT_DIR, f"{project_name}_original.txt")
        shutil.copy(manuscript_file, manuscript_copy)
        
        logger.info(f"Processing manuscript: {manuscript_title} (Project ID: {project_name})")
        
        # Run the chunking script
        logger.info("Chunking manuscript into manageable pieces...")
        chunk_cmd = [
            "python3", os.path.join(self.config.TEMP_DIR, "chunk_manuscript.py"),
            manuscript_copy,
            "--output_dir", self.config.CHUNKS_DIR,
            "--project_name", project_name,
            "--max_tokens", str(self.config.chunk_size),
            "--overlap_tokens", str(self.config.chunk_overlap)
        ]
        
        try:
            subprocess.run(chunk_cmd, check=True)
        except subprocess.CalledProcessError as e:
            logger.error(f"Error during chunking: {str(e)}")
            return False
        
        # Check if chunking was successful
        metadata_file = os.path.join(self.config.CHUNKS_DIR, f"{project_name}_metadata.json")
        if not os.path.isfile(metadata_file):
            logger.error("Chunking failed. Metadata file not found.")
            return False
        
        # Extract metadata
        with open(metadata_file, 'r') as f:
            metadata = json.load(f)
            total_chunks = metadata.get('total_chunks', 0)
        
        logger.info(f"Manuscript split into {total_chunks} chunks")
        
        # Update DynamoDB with metadata
        session = boto3.Session(
            region_name=self.config.aws_region,
            profile_name=self.config.aws_profile
        )
        dynamodb = session.resource('dynamodb')
        
        state_table = f"{self.config.table_prefix}_{project_name}_state"
        table = dynamodb.Table(state_table)
        
        try:
            table.update_item(
                Key={
                    "manuscript_id": project_name,
                    "chunk_id": "metadata"
                },
                UpdateExpression="SET title = :t, total_chunks = :c, current_phase = :p, updated_at = :u",
                ExpressionAttributeValues={
                    ":t": manuscript_title,
                    ":c": total_chunks,
                    ":p": "assessment", 
                    ":u": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                }
            )
        except Exception as e:
            logger.error(f"Error updating DynamoDB: {str(e)}")
            return False
        
        # Run initial manuscript assessment
        logger.info("Performing initial manuscript assessment...")
        assessment_cmd = [
            "python3", os.path.join(self.config.TEMP_DIR, "assess_manuscript.py"),
            "--chunks_dir", self.config.CHUNKS_DIR,
            "--project_name", project_name,
            "--region", self.config.aws_region,
            "--model_id", self.config.default_model,
            "--table_prefix", self.config.table_prefix
        ]
        
        try:
            subprocess.run(assessment_cmd, check=True)
        except subprocess.CalledProcessError as e:
            logger.error(f"Error during assessment: {str(e)}")
            return False
            
        # Check if assessment was successful
        assessment_file = os.path.join(self.config.CHUNKS_DIR, f"{project_name}_assessment.json")
        if not os.path.isfile(assessment_file):
            logger.error("Assessment failed. Assessment file not found.")
            return False
            
        logger.info("Initial manuscript assessment complete")
        return True
    
    def process_chunks(self, project_name: str) -> bool:
        """Process manuscript chunks in parallel."""
        logger.info(f"Processing chunks for project {project_name}")
        
        # Load project configuration
        project_config_file = f"{project_name}_config.json"
        if not os.path.isfile(project_config_file):
            logger.error(f"Project configuration file not found: {project_config_file}")
            return False
        
        with open(project_config_file, 'r') as f:
            project_config = json.load(f)
        
        # Get metadata
        metadata_file = os.path.join(self.config.CHUNKS_DIR, f"{project_name}_metadata.json")
        if not os.path.isfile(metadata_file):
            logger.error(f"Metadata file not found: {metadata_file}")
            return False
        
        with open(metadata_file, 'r') as f:
            metadata = json.load(f)
            total_chunks = metadata.get('total_chunks', 0)
            chunk_files = metadata.get('chunk_files', [])
        
        # Get assessment data
        assessment_file = os.path.join(self.config.CHUNKS_DIR, f"{project_name}_assessment.json")
        if not os.path.isfile(assessment_file):
            logger.error(f"Assessment file not found: {assessment_file}")
            return False
        
        with open(assessment_file, 'r') as f:
            assessment = json.load(f)
        
        # Extract flow IDs
        flows = project_config.get('flows', {})
        improvement_flow = flows.get('improvement', {})
        improvement_flow_id = improvement_flow.get('flow_id')
        improvement_alias_id = improvement_flow.get('alias_id')
        
        if not improvement_flow_id or not improvement_alias_id:
            logger.error("Improvement flow information missing from project config")
            return False
        
        # Extract improvement focus from assessment
        content_assessment = assessment.get('content_assessment', {})
        if isinstance(content_assessment, dict) and 'improvement_recommendations' in content_assessment:
            improvement_focus = ", ".join(content_assessment['improvement_recommendations'])
        else:
            improvement_focus = "Improve overall quality, pacing, character development, dialogue, and prose style"
        
        logger.info(f"Processing {len(chunk_files)} chunks for manuscript improvement")
        logger.info(f"Improvement focus: {improvement_focus}")
        
        # Setup parallel processing
        max_parallel = min(5, multiprocessing.cpu_count())
        
        # Create output directory for improved chunks
        improved_dir = os.path.join(self.config.CHUNKS_DIR, f"{project_name}_improved")
        os.makedirs(improved_dir, exist_ok=True)
        
        # Prepare session for flow invocation
        session = boto3.Session(
            region_name=self.config.aws_region,
            profile_name=self.config.aws_profile
        )
        bedrock_agent_runtime = session.client('bedrock-agent-runtime')
        
        # Create a pool of workers
        with multiprocessing.Pool(processes=max_parallel) as pool:
            # Prepare chunk processing tasks
            tasks = []
            
            for i, chunk_file in enumerate(chunk_files):
                chunk_id = f"chunk_{i+1:04d}"
                improved_file = os.path.join(improved_dir, f"{chunk_id}.txt")
                
                # Skip if already processed
                if os.path.isfile(improved_file):
                    logger.info(f"Chunk {chunk_id} already processed, skipping...")
                    continue
                
                tasks.append((
                    project_name, 
                    chunk_id, 
                    chunk_file, 
                    improved_file, 
                    improvement_focus,
                    improvement_flow_id,
                    improvement_alias_id
                ))
            
            # Process chunks in parallel
            results = pool.starmap(self._process_single_chunk, tasks)
        
        # Check results
        success_count = sum(1 for result in results if result)
        logger.info(f"Processed {success_count} chunks successfully out of {len(tasks)}")
        
        # Combine improved chunks into final manuscript
        if success_count > 0:
            final_manuscript = os.path.join(self.config.MANUSCRIPT_DIR, f"{project_name}_improved.txt")
            
            with open(final_manuscript, 'w') as outfile:
                for i in range(len(chunk_files)):
                    chunk_id = f"chunk_{i+1:04d}"
                    improved_file = os.path.join(improved_dir, f"{chunk_id}.txt")
                    
                    if os.path.isfile(improved_file):
                        with open(improved_file, 'r') as infile:
                            outfile.write(infile.read())
                        outfile.write("\n\n")
                    else:
                        logger.warning(f"Improved file not found for chunk {chunk_id}")
            
            # Update project state
            dynamodb = session.resource('dynamodb')
            state_table = f"{self.config.table_prefix}_{project_name}_state"
            table = dynamodb.Table(state_table)
            
            try:
                table.update_item(
                    Key={
                        "manuscript_id": project_name,
                        "chunk_id": "metadata"
                    },
                    UpdateExpression="SET current_phase = :p, updated_at = :u",
                    ExpressionAttributeValues={
                        ":p": "finalization",
                        ":u": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                    }
                )
            except Exception as e:
                logger.error(f"Error updating project state: {str(e)}")
            
            logger.info(f"Final improved manuscript saved to: {final_manuscript}")
            return True
        else:
            logger.error("No chunks were processed successfully")
            return False
    
    def _process_single_chunk(self, project_name: str, chunk_id: str, chunk_file: str, 
                           improved_file: str, improvement_focus: str,
                           flow_id: str, alias_id: str) -> bool:
        """Process a single manuscript chunk."""
        try:
            logger.info(f"Processing chunk {chunk_id}...")
            
            # Read chunk text
            with open(chunk_file, 'r') as f:
                chunk_text = f.read()
            
            # Prepare flow inputs
            inputs = [
                {
                    "content": {
                        "manuscript_id": project_name,
                        "chunk_id": chunk_id,
                        "chunk_text": chunk_text,
                        "improvement_focus": improvement_focus,
                        "editing_notes": ""
                    },
                    "nodeName": "FlowInputNode",
                    "nodeOutputNames": ["manuscript_id", "chunk_id", "chunk_text", "improvement_focus", "editing_notes"]
                }
            ]
            
            # Create session
            session = boto3.Session(
                region_name=self.config.aws_region,
                profile_name=self.config.aws_profile
            )
            bedrock_agent_runtime = session.client('bedrock-agent-runtime')
            
            # Invoke flow
            response = bedrock_agent_runtime.invoke_flow(
                flowIdentifier=flow_id,
                flowAliasIdentifier=alias_id,
                inputs=inputs
            )
            
            # Extract results
            outputs = response.get('outputs', [])
            final_revision = None
            
            for output in outputs:
                if output.get('name') == 'final_revision':
                    final_revision = output.get('content')
                    break
            
            if not final_revision:
                logger.error(f"No final revision found in flow output for chunk {chunk_id}")
                return False
            
            # Save improved chunk
            with open(improved_file, 'w') as f:
                f.write(final_revision)
            
            # Update DynamoDB
            dynamodb = session.resource('dynamodb')
            
            # Store in edits table
            edits_table = f"{self.config.table_prefix}_{project_name}_edits"
            edits_table_resource = dynamodb.Table(edits_table)
            
            edits_table_resource.put_item(
                Item={
                    "edit_id": chunk_id,
                    "manuscript_id": project_name,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "original_text": chunk_text,
                    "improved_text": final_revision,
                    "improvement_type": "content"
                }
            )
            
            # Update progress
            state_table = f"{self.config.table_prefix}_{project_name}_state"
            state_table_resource = dynamodb.Table(state_table)
            
            state_table_resource.update_item(
                Key={
                    "manuscript_id": project_name,
                    "chunk_id": "metadata"
                },
                UpdateExpression="SET chunks_processed = chunks_processed + :val, updated_at = :u",
                ExpressionAttributeValues={
                    ":val": 1,
                    ":u": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                }
            )
            
            logger.info(f"Completed chunk {chunk_id}")
            return True
            
        except Exception as e:
            logger.error(f"Error processing chunk {chunk_id}: {str(e)}")
            return False
    
    def finalize_manuscript(self, project_name: str) -> bool:
        """Finalize manuscript."""
        logger.info(f"Finalizing manuscript for project {project_name}")
        
        # Load project configuration
        project_config_file = f"{project_name}_config.json"
        if not os.path.isfile(project_config_file):
            logger.error(f"Project configuration file not found: {project_config_file}")
            return False
        
        with open(project_config_file, 'r') as f:
            project_config = json.load(f)
        
        # Get manuscript title and final manuscript
        title = project_config.get('title', project_name)
        final_manuscript = os.path.join(self.config.MANUSCRIPT_DIR, f"{project_name}_improved.txt")
        
        if not os.path.isfile(final_manuscript):
            logger.error(f"Improved manuscript not found: {final_manuscript}")
            return False
        
        # Get assessment data
        assessment_file = os.path.join(self.config.CHUNKS_DIR, f"{project_name}_assessment.json")
        if not os.path.isfile(assessment_file):
            logger.error(f"Assessment file not found: {assessment_file}")
            return False
        
        with open(assessment_file, 'r') as f:
            assessment = json.load(f)
        
        # Extract flow IDs
        flows = project_config.get('flows', {})
        finalization_flow = flows.get('finalization', {})
        finalization_flow_id = finalization_flow.get('flow_id')
        finalization_alias_id = finalization_flow.get('alias_id')
        
        if not finalization_flow_id or not finalization_alias_id:
            logger.error("Finalization flow information missing from project config")
            return False
        
        # Need to process manuscript in chunks for finalization too
        chunk_size = 20000  # Characters, not tokens for this step
        
        with open(final_manuscript, 'r') as f:
            full_text = f.read()
            
        total_size = len(full_text)
        num_chunks = (total_size + chunk_size - 1) // chunk_size
        
        logger.info(f"Splitting manuscript into {num_chunks} chunks for final review")
        
        # Create finalization directory
        final_dir = os.path.join(self.config.CHUNKS_DIR, f"{project_name}_final")
        os.makedirs(final_dir, exist_ok=True)
        
        # Split manuscript into chunks
        chunks = []
        for i in range(num_chunks):
            start = i * chunk_size
            end = min((i + 1) * chunk_size, total_size)
            chunks.append(full_text[start:end])
        
        # Get previous assessment
        content_assessment = json.dumps(assessment.get('content_assessment', {}))
        
        # Create session
        session = boto3.Session(
            region_name=self.config.aws_region,
            profile_name=self.config.aws_profile
        )
        bedrock_agent_runtime = session.client('bedrock-agent-runtime')
        
        # Process each chunk for finalization
        final_outputs = []
        summaries = []
        
        for i, chunk_text in enumerate(chunks):
            chunk_id = f"final_chunk_{i+1:04d}"
            logger.info(f"Finalizing chunk {chunk_id}")
            
            # Save chunk to file for reference
            chunk_file = os.path.join(final_dir, chunk_id)
            with open(chunk_file, 'w') as f:
                f.write(chunk_text)
            
            # Prepare flow inputs
            inputs = [
                {
                    "content": {
                        "manuscript_id": project_name,
                        "title": title,
                        "final_text": chunk_text,
                        "previous_assessment": content_assessment
                    },
                    "nodeName": "FlowInputNode",
                    "nodeOutputNames": ["manuscript_id", "title", "final_text", "previous_assessment"]
                }
            ]
            
            # Invoke flow
            try:
                response = bedrock_agent_runtime.invoke_flow(
                    flowIdentifier=finalization_flow_id,
                    flowAliasIdentifier=finalization_alias_id,
                    inputs=inputs
                )
                
                # Extract results
                outputs = response.get('outputs', [])
                final_polished = None
                executive_summary = None
                
                for output in outputs:
                    if output.get('name') == 'final_polished_text':
                        final_polished = output.get('content')
                    elif output.get('name') == 'executive_summary':
                        executive_summary = output.get('content')
                
                if final_polished:
                    final_outputs.append(final_polished)
                    
                    # Save polished chunk
                    with open(f"{chunk_file}_polished.txt", 'w') as f:
                        f.write(final_polished)
                
                if executive_summary:
                    summaries.append(executive_summary)
                    
                    # Save executive summary
                    with open(os.path.join(final_dir, f"executive_summary_{chunk_id}.txt"), 'w') as f:
                        f.write(executive_summary)
                        
            except Exception as e:
                logger.error(f"Error finalizing chunk {chunk_id}: {str(e)}")
        
        # Combine finalized chunks into final manuscript
        bestseller_manuscript = os.path.join(self.config.MANUSCRIPT_DIR, f"{project_name}_bestseller.txt")
        with open(bestseller_manuscript, 'w') as f:
            for output in final_outputs:
                f.write(output)
                f.write("\n\n")
        
        # Combine executive summaries
        combined_summary = os.path.join(self.config.MANUSCRIPT_DIR, f"{project_name}_executive_summary.txt")
        with open(combined_summary, 'w') as f:
            for summary in summaries:
                f.write(summary)
                f.write("\n\n" + "-" * 80 + "\n\n")
        
        # Update project state
        dynamodb = session.resource('dynamodb')
        state_table = f"{self.config.table_prefix}_{project_name}_state"
        table = dynamodb.Table(state_table)
        
        try:
            table.update_item(
                Key={
                    "manuscript_id": project_name,
                    "chunk_id": "metadata"
                },
                UpdateExpression="SET current_phase = :p, updated_at = :u",
                ExpressionAttributeValues={
                    ":p": "complete",
                    ":u": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                }
            )
        except Exception as e:
            logger.error(f"Error updating project state: {str(e)}")
        
        logger.info(f"Final best-seller manuscript saved to: {bestseller_manuscript}")
        logger.info(f"Executive summary saved to: {combined_summary}")
        
        return True
    
    def get_chunk_text(self, project_name: str, chunk_id: str) -> Optional[str]:
        """Get text for a specific chunk."""
        # Try improved chunks first
        improved_dir = os.path.join(self.config.CHUNKS_DIR, f"{project_name}_improved")
        improved_file = os.path.join(improved_dir, f"{chunk_id}.txt")
        
        if os.path.isfile(improved_file):
            with open(improved_file, 'r') as f:
                return f.read()
        
        # Try to find in original chunks
        metadata_file = os.path.join(self.config.CHUNKS_DIR, f"{project_name}_metadata.json")
        
        if os.path.isfile(metadata_file):
            with open(metadata_file, 'r') as f:
                metadata = json.load(f)
                
            # Extract chunk number
            match = re.search(r'chunk_0*(\d+)', chunk_id)
            if match:
                chunk_num = int(match.group(1))
                chunk_files = metadata.get('chunk_files', [])
                
                if 0 < chunk_num <= len(chunk_files):
                    chunk_file = chunk_files[chunk_num-1]
                    
                    if os.path.isfile(chunk_file):
                        with open(chunk_file, 'r') as f:
                            return f.read()
        
        logger.warning(f"Could not find text for chunk {chunk_id}")
        return None
    
    def _generate_chunking_script(self) -> None:
        """Generate Python script for manuscript chunking."""
        script_path = os.path.join(self.config.TEMP_DIR, "chunk_manuscript.py")
        
        if os.path.isfile(script_path):
            return
            
        script_content = r'''#!/usr/bin/env python3
import os
import sys
import json
import re
import tiktoken
import nltk
from nltk.tokenize import sent_tokenize
import argparse

def count_tokens(text: str, encoding_name: str = "cl100k_base") -> int:
    """Count the number of tokens in a text string."""
    encoding = tiktoken.get_encoding(encoding_name)
    return len(encoding.encode(text))

def chunk_text(text, max_tokens=8000, overlap_tokens=500):
    """Split text into chunks of approximately max_tokens with overlap."""
    sentences = sent_tokenize(text)
    chunks = []
    current_chunk = []
    current_token_count = 0
    
    for sentence in sentences:
        sentence_token_count = count_tokens(sentence)
        if current_token_count + sentence_token_count > max_tokens and current_chunk:
            chunks.append(" ".join(current_chunk))
            overlap_text = []
            overlap_token_count = 0
            for i in range(len(current_chunk) - 1, -1, -1):
                sentence_for_overlap = current_chunk[i]
                sentence_overlap_tokens = count_tokens(sentence_for_overlap)
                if overlap_token_count + sentence_overlap_tokens <= overlap_tokens:
                    overlap_text.insert(0, sentence_for_overlap)
                    overlap_token_count += sentence_overlap_tokens
                else:
                    break
            current_chunk = overlap_text
            current_token_count = overlap_token_count
        current_chunk.append(sentence)
        current_token_count += sentence_token_count
    
    if current_chunk:
        chunks.append(" ".join(current_chunk))
    return chunks

def detect_chapters(text):
    """Identify chapter breaks in the text."""
    chapter_patterns = [
        r'(?i)^chapter\s+\d+',
        r'(?i)^chapter\s+[IVXLCDM]+',
        r'(?i)^\d+\.\s+',
        r'(?m)^\s*CHAPTER\s+(?:\d+|[IVXLCDM]+)'
    ]
    chapter_matches = []
    for pattern in chapter_patterns:
        matches = re.finditer(pattern, text, re.MULTILINE)
        for match in matches:
            chapter_matches.append((match.start(), match.group()))
    chapter_matches.sort()
    return chapter_matches

def save_chunks(chunks, output_dir, project_name):
    """Save chunks to individual files."""
    os.makedirs(output_dir, exist_ok=True)
    chunk_files = []
    
    for i, chunk in enumerate(chunks):
        file_path = os.path.join(output_dir, f"{project_name}_chunk_{i+1:04d}.txt")
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(chunk)
        chunk_files.append(file_path)
    
    metadata = {
        "project_name": project_name,
        "total_chunks": len(chunks),
        "chunk_files": chunk_files,
        "token_counts": [count_tokens(chunk) for chunk in chunks]
    }
    
    with open(os.path.join(output_dir, f"{project_name}_metadata.json"), "w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2)
    
    return metadata

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Split manuscript into chunks for processing")
    parser.add_argument("manuscript_path", help="Path to manuscript file")
    parser.add_argument("--output_dir", default="./chunks", help="Directory to save chunks")
    parser.add_argument("--project_name", required=True, help="Project name")
    parser.add_argument("--max_tokens", type=int, default=8000, help="Maximum tokens per chunk")
    parser.add_argument("--overlap_tokens", type=int, default=500, help="Token overlap between chunks")
    
    args = parser.parse_args()
    
    try:
        with open("./config.json", "r", encoding="utf-8") as f:
            config = json.load(f)
            max_tokens = config.get("chunk_size", args.max_tokens)
            overlap_tokens = config.get("chunk_overlap", args.overlap_tokens)
    except:
        max_tokens = args.max_tokens
        overlap_tokens = args.overlap_tokens
    
    try:
        nltk.data.find("tokenizers/punkt")
    except LookupError:
        nltk.download("punkt")
    
    with open(args.manuscript_path, "r", encoding="utf-8") as f:
        manuscript_text = f.read()
    
    text_chunks = chunk_text(manuscript_text, max_tokens, overlap_tokens)
    metadata = save_chunks(text_chunks, args.output_dir, args.project_name)
    
    print(f"Manuscript split into {len(text_chunks)} chunks. Metadata saved.")
    print(json.dumps(metadata))
'''

        with open(script_path, "w", encoding="utf-8") as f:
            f.write(script_content)
            
        os.chmod(script_path, 0o755)
        logger.info(f"Chunking script generated: {script_path}")

    def _generate_assessment_script(self) -> None:
        """Generate Python script for manuscript assessment."""
        script_path = os.path.join(self.config.TEMP_DIR, "assess_manuscript.py")
        
        if os.path.isfile(script_path):
            return
            
        script_content = r'''#!/usr/bin/env python3
import os
import sys
import json
import boto3
import argparse
from datetime import datetime

def assess_chunk(chunk_text: str, model_id: str, region: str) -> str:
    """Assess a single chunk of text using a specified model."""
    session = boto3.Session(region_name=region)
    bedrock = session.client("bedrock")
    response = bedrock.invoke_model(
        modelId=model_id,
        contentType="text/plain",
        content=chunk_text
    )
    return response["body"].read().decode("utf-8")

def main():
    """Main entry point for manuscript assessment script."""
    parser = argparse.ArgumentParser(description="Assess manuscript chunks")
    parser.add_argument("--chunks_dir", required=True, help="Directory containing manuscript chunks")
    parser.add_argument("--project_name", required=True, help="Project name")
    parser.add_argument("--region", required=True, help="AWS region")
    parser.add_argument("--model_id", required=True, help="Model ID for assessment")
    parser.add_argument("--table_prefix", required=True, help="DynamoDB table prefix")
    
    args = parser.parse_args()
    
    metadata_file = os.path.join(args.chunks_dir, f"{args.project_name}_metadata.json")
    with open(metadata_file, "r", encoding="utf-8") as f:
        metadata = json.load(f)
    
    chunk_files = metadata["chunk_files"]
    assessments = []
    
    for chunk_file in chunk_files:
        with open(chunk_file, "r", encoding="utf-8") as f:
            chunk_text = f.read()
        assessment = assess_chunk(chunk_text, args.model_id, args.region)
        assessments.append(assessment)
    
    assessment_file = os.path.join(args.chunks_dir, f"{args.project_name}_assessment.json")
    with open(assessment_file, "w", encoding="utf-8") as f:
        json.dump(assessments, f, indent=2)
    
    session = boto3.Session(region_name=args.region)
    dynamodb = session.resource("dynamodb")
    state_table = f"{args.table_prefix}_{args.project_name}_state"
    table = dynamodb.Table(state_table)
    
    try:
        table.update_item(
            Key={
                "manuscript_id": args.project_name,
                "chunk_id": "metadata"
            },
            UpdateExpression="SET current_phase = :p, updated_at = :u",
            ExpressionAttributeValues={
                ":p": "improvement",
                ":u": datetime.utcnow().isoformat()
            }
        )
    except Exception as e:
        print(f"Error updating DynamoDB: {str(e)}")
        sys.exit(1)
    
    print("Manuscript assessment complete")

if __name__ == "__main__":
    main()
'''
        
        with open(script_path, "w", encoding="utf-8") as f:
            f.write(script_content)
            
        os.chmod(script_path, 0o755)
        logger.info(f"Assessment script generated: {script_path}")
