#!/usr/bin/env python3
import os
import sys
import json
import boto3
import argparse
from datetime import datetime

def assess_chunk(chunk_text: str, model_id: str, region: str) -> str:
    """Assess a single chunk of text using a specified model.
    
    Args:
        chunk_text: The text chunk to assess
        model_id: The Bedrock model ID to use
        region: AWS region name
        
    Returns:
        Assessment results as a string
    """
    session = boto3.Session(region_name=region)
    bedrock = session.client('bedrock')
    
    response = bedrock.invoke_model(
        modelId=model_id,
        contentType='text/plain',
        content=chunk_text
    )
    
    return response['body'].read().decode('utf-8')

def main():
    """Main entry point for manuscript assessment script."""
    parser = argparse.ArgumentParser(description='Assess manuscript chunks')
    parser.add_argument('--chunks_dir', required=True, help='Directory containing manuscript chunks')
    parser.add_argument('--project_name', required=True, help='Project name')
    parser.add_argument('--region', required=True, help='AWS region')
    parser.add_argument('--model_id', required=True, help='Model ID for assessment')
    parser.add_argument('--table_prefix', required=True, help='DynamoDB table prefix')
    
    args = parser.parse_args()
    
    # Load chunk metadata
    metadata_file = os.path.join(args.chunks_dir, f"{args.project_name}_metadata.json")
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)
    
    chunk_files = metadata['chunk_files']
    
    # Assess each chunk
    assessments = []
    for chunk_file in chunk_files:
        with open(chunk_file, 'r') as f:
            chunk_text = f.read()
        
        assessment = assess_chunk(chunk_text, args.model_id, args.region)
        assessments.append(assessment)
    
    # Save assessments to file
    assessment_file = os.path.join(args.chunks_dir, f"{args.project_name}_assessment.json")
    with open(assessment_file, 'w') as f:
        json.dump(assessments, f, indent=2)
    
    # Update DynamoDB with assessment results
    session = boto3.Session(region_name=args.region)
    dynamodb = session.resource('dynamodb')
    
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
