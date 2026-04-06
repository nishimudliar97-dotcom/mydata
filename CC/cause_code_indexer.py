from langchain_huggingface import HuggingFaceEmbeddings
from langchain_core.documents import Document
from langchain_community.vectorstores import FAISS
from dotenv import load_dotenv
import os

load_dotenv()

HF_TOKEN = os.getenv("HUGGING_FACE_TOKEN")


def create_cause_code_faiss_index(cause_code_rows):
    """
    Builds a FAISS vector store from MySQL cause_code table rows.
    """

    embedding_model = HuggingFaceEmbeddings(
        model_name="BAAI/bge-base-en",
        model_kwargs={"device": "cpu", "token": HF_TOKEN},
        encode_kwargs={"normalize_embeddings": True}
    )

    documents = []

    for row in cause_code_rows:
        cause_code_id = row.get("cause_code_id")
        cause_l1 = row.get("cause_l1") or ""
        cause_l2 = row.get("cause_l2") or ""

        page_content = (
            f"Cause L1: {cause_l1}\n"
            f"Cause L2: {cause_l2}\n"
            f"Cause Code ID: {cause_code_id}"
        )

        metadata = {
            "cause_code_id": cause_code_id,
            "cause_l1": cause_l1,
            "cause_l2": cause_l2
        }

        documents.append(
            Document(
                page_content=page_content,
                metadata=metadata
            )
        )

    if not documents:
        raise ValueError("No cause code rows found to build FAISS index.")

    vector_store = FAISS.from_documents(documents, embedding_model)
    return vector_store
