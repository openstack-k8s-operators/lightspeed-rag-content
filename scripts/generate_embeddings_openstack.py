#!/usr/bin/env python3

"""Utility script to generate embeddings."""

import logging
import re
import json
from pathlib import Path
import sys

from lightspeed_rag_content import utils
from lightspeed_rag_content.metadata_processor import MetadataProcessor
from lightspeed_rag_content.document_processor import DocumentProcessor
from llama_index.readers.file.markdown.base import MarkdownReader

logging.basicConfig(
    level=logging.WARNING, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)


class OpenStackDocsMetadataProcessor(MetadataProcessor):
    """Metadata processor for OpenStack documentation."""

    def __init__(self, folder_path: str):
        super(OpenStackDocsMetadataProcessor, self).__init__()
        self.folder_path = Path(folder_path)
        self.base_url = "https://docs.openstack.org"

    def url_function(self, path: str) -> str:
        """Generate the URL for a document based on its file path."""
        path_obj = Path(path).resolve()
        try:
            relative_path = path_obj.relative_to(self.folder_path.resolve())
        except ValueError:
            relative_path = path_obj.name

        relative_path = relative_path.as_posix()

        # Remove _docs suffix: /cinder/2025.2_docs/ → /cinder/2025.2/
        relative_path = re.sub(r"/(\d+\.\d+)_docs/", r"/\1/", relative_path)

        # Remove _api-ref suffix: /cinder/2025.2_api-ref/ → /cinder/2025.2/api-ref/
        relative_path = re.sub(r"/(\d+\.\d+)_api-ref/", r"/\1/api-ref/", relative_path)

        # Handle "latest" version
        relative_path = relative_path.replace("/latest_docs/", "/latest/")
        relative_path = relative_path.replace("/latest_api-ref/", "/latest/api-ref/")

        # Replace .txt with .html
        relative_path = relative_path.replace(".txt", ".html")

        return f"{self.base_url}/{relative_path}"


# Extra docs metadata processor
class ExtraDocsMetadataProcessor(MetadataProcessor):
    """Metadata processor for extra SME-authored documentation."""

    def __init__(self, folder_path: str | Path):
        super(ExtraDocsMetadataProcessor, self).__init__()
        self.folder_path = Path(folder_path).resolve()

    def url_function(self, file_path: str) -> str:
        return ""

    def populate(self, file_path: str) -> dict:
        metadata = {"docs_url": "", "url_reachable": False}
        path_obj = Path(file_path).resolve()
        try:
            relative_path = path_obj.relative_to(self.folder_path)
        except ValueError:
            relative_path = Path(path_obj.name)
        metadata["filepath"] = relative_path.as_posix()

        meta_path = Path(file_path).with_suffix(".meta")
        if meta_path.exists():
            try:
                with meta_path.open() as f:
                    meta_content = json.load(f)
                metadata.update(meta_content)
            except json.JSONDecodeError as e:
                print(
                    f"Error: Invalid JSON in '{meta_path}': {e}",
                    file=sys.stderr,
                )
                sys.exit(1)

        title = self.get_file_title(file_path)
        if title and "title" not in metadata:
            metadata["title"] = title

        return metadata


#
# Functions related to Openstack Operators
#


class OpenStackOperatorMetadataProcessor(MetadataProcessor):
    """Metadata processor for OpenStack OpenShift Operators Documentation"""

    def __init__(self, folder_path: str):
        super(OpenStackOperatorMetadataProcessor, self).__init__()
        self.folder_path = Path(folder_path)
        self.base_url = "https://openstack-k8s-operators.github.io/openstack-operator"

    def url_function(self, path: str) -> str:
        """Generate the URL for a document based on its file path."""
        path_obj = Path(path).resolve()
        try:
            relative_path = path_obj.relative_to(self.folder_path.resolve())
        except ValueError:
            relative_path = path_obj.name

        relative_path = relative_path.as_posix()

        # Replace .md with / for dir-style URLs
        # ctlplane/index.md -> ctlplane/
        # dataplane/index.md -> dataplane/
        relative_path = relative_path.replace("/index.md", "/")

        # For other files, replace .md with .html
        relative_path = relative_path.replace(".md", ".html")

        return f"{self.base_url}/{relative_path}"


if __name__ == "__main__":
    parser = utils.get_common_arg_parser()
    parser.add_argument(
        "-opf",
        "--operators-folder",
        type=Path,
        required=False,
        help="Directory containing the plain text OpenStack Operators documentation",
    )
    parser.add_argument(
        "-ua",
        "--unreachable-action",
        choices=["warn", "drop", "fail"],
        default="warn",
        required=False,
        help="What to do when encountering a doc whose URL can't be reached",
    )
    parser.add_argument(
        "-il",
        "--ignore-list",
        type=str,
        nargs="?",
        const="",
        required=False,
        default="",
        help="Comma-separated list of document titles to ignore URL validation for",
    )
    parser.add_argument(
        "-ef",
        "--extra-folder",
        type=Path,
        action="append",
        default=[],
        required=False,
        help="Additional folders with markdown/txt docs to include (e.g. rag-docs/extra-docs)",
    )

    # Change the default chunking mode from 'text' to 'markdown'
    parser.set_defaults(doc_type="markdown")

    args = parser.parse_args()

    # Parse ignore list from command-line argument
    ignore_list = [
        title.strip() for title in args.ignore_list.split(",") if title.strip()
    ]

    if not any(
        [
            args.folder,
            args.operators_folder,
            args.extra_folder,
        ]
    ):
        print(
            'Error: At least one of "--folder", '
            '"--operators-folder", or "--extra-folder" options '
            "must be provided",
            file=sys.stderr,
        )
        sys.exit(1)

    # Instantiate Document Processor
    document_processor = DocumentProcessor(
        args.chunk,
        args.overlap,
        args.model_name,
        str(args.model_dir),
        args.workers,
        args.vector_store_type,
        args.index.replace("-", "_"),
        manual_chunking=args.manual_chunking,
        doc_type=args.doc_type,
    )

    # Process the OpenStack documents, if provided
    if args.folder:
        document_processor.process(
            str(args.folder),
            metadata=OpenStackDocsMetadataProcessor(args.folder),
            required_exts=[
                ".txt",
            ],
            unreachable_action=args.unreachable_action,
            ignore_list=ignore_list,
        )

    # Process extra-docs folders (e.g. SME content from rag-docs/extra-docs)
    for extra in args.extra_folder:
        if not extra.exists():
            print(
                f"Error: Extra folder '{extra}' does not exist",
                file=sys.stderr,
            )
            sys.exit(1)
        if not extra.is_dir():
            print(
                f"Error: Extra folder '{extra}' is not a directory",
                file=sys.stderr,
            )
            sys.exit(1)
        # NOTE(lucas): unreachable_action for extra_docs is marked as
        # "warn" always because extra_docs are meant for SME and personal
        # notes/documents. Having it to "fail" will cause the build to
        # fail since most of these documents do not have any valid link.
        document_processor.process(
            str(extra),
            metadata=ExtraDocsMetadataProcessor(extra),
            required_exts=[".md", ".txt"],
            unreachable_action="warn",
            ignore_list=ignore_list,
        )

    # Process the OpenStack Operators document, if provided
    if args.operators_folder:
        document_processor.process(
            str(args.operators_folder),
            metadata=OpenStackOperatorMetadataProcessor(args.operators_folder),
            required_exts=[
                ".md",
            ],
            file_extractor={".md": MarkdownReader()},
            unreachable_action=args.unreachable_action,
            ignore_list=ignore_list,
        )

    # Save to the output directory
    document_processor.save(args.index, str(args.output))
