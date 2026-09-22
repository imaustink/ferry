# A big image, because several of the costs here scale with it and none of
# them show up on alpine: the export tarball, the load into ferry's image
# store, and the ext4 unpack a pod VM needs before it can boot.
#
# Experiment 16 used this base for the same reason.
FROM public.ecr.aws/docker/library/python:3.12
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY src ./src
CMD ["python", "src/main.py"]
