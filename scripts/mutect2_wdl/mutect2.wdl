#  Run Mutect 2 on a single tumor-normal pair or on a single tumor sample.
#
#  Description of inputs
#  gatk4_jar: java jar file containing gatk 4 (protected)
#  intervals: genomic intervals
#  ref_fasta, ref_fasta_index, ref_dict: reference genome, index, and dictionary
#  tumor_bam, tumor_bam_index, and tumor_sample_name: self-explanatory
#  normal_bam, normal_bam_index, and normal_sample_name: self-explanatory
#  pon, pon_index: optional panel of normals and index in vcf format containing known false positves
#  scatter_count: number of parallel jobs when scattering over intervals
#  gnomad, gnomad_index: optional database of known germline variants, obtainable from http://gnomad.broadinstitute.org/downloads
#  variants_for_contamination, variants_for_contamination_index: vcf of common variants with allele frequencies fo calculating contamination
#  is_run_orientation_bias_filter: if true, run the orientation bias filter post-processing step
#  is_run_oncotator: if true, annotate the M2 VCFs using oncotator.  Important:  This requires a docker image and should
#   not be run in environments where docker is unavailable (e.g. SGE cluster on a Broad on-prem VM).  Access to docker
#   hub is also required, since the task will download a public docker image.
#
#
# This WDL needs to decide whether to use the ``gatk_jar`` or ``gatk_jar_override`` for the jar location.  As of cromwell-0.24,
#   this logic *must* go into each task.  Therefore, there is a lot of duplicated code.  This allows users to specify a jar file
#   independent of what is in the docker file.  See the README.md for more info.
#


workflow Mutect2 {
  # gatk4_jar needs to be a String input to the workflow in order to work in a Docker image
  String gatk4_jar
  File? intervals
  File ref_fasta
  File ref_fasta_index
  File ref_dict
  File tumor_bam
  File tumor_bam_index
  String tumor_sample_name
  File? normal_bam
  File? normal_bam_index
  String? normal_sample_name
  File? pon
  File? pon_index
  Int scatter_count
  File? gnomad
  File? gnomad_index
  File? variants_for_contamination
  File? variants_for_contamination_index
  Boolean is_run_orientation_bias_filter
  Boolean is_run_oncotator
  String m2_docker
  String oncotator_docker
  File? gatk4_jar_override
  Int preemptible_attempts
  File? onco_ds_tar_gz
  String? onco_ds_local_db_dir
  Array[String] artifact_modes
  File picard_jar
  String? m2_args
  String? m2_filtering_args

  call ProcessOptionalArguments {
    input:
      tumor_sample_name = tumor_sample_name,
      normal_bam = normal_bam,
      normal_sample_name = normal_sample_name,
      preemptible_attempts = preemptible_attempts,
      m2_docker=m2_docker
  }


  call SplitIntervals {
    input:
      gatk4_jar = gatk4_jar,
      scatter_count = scatter_count,
      intervals = intervals,
      ref_fasta = ref_fasta,
      ref_fasta_index = ref_fasta_index,
      ref_dict = ref_dict,
      gatk4_jar_override = gatk4_jar_override,
      preemptible_attempts = preemptible_attempts,
      m2_docker = m2_docker

  }

  scatter (subintervals in SplitIntervals.interval_files ) {
    call M2 {
      input: 
        gatk4_jar = gatk4_jar,
        intervals = subintervals,
        ref_fasta = ref_fasta,
        ref_fasta_index = ref_fasta_index,
        ref_dict = ref_dict,
        tumor_bam = tumor_bam,
        tumor_bam_index = tumor_bam_index,
        tumor_sample_name = tumor_sample_name,
        normal_bam = normal_bam,
        normal_bam_index = normal_bam_index,
        normal_sample_name = normal_sample_name,
        pon = pon,
        pon_index = pon_index,
        gnomad = gnomad,
        gnomad_index = gnomad_index,
        output_vcf_name = ProcessOptionalArguments.output_name,
        gatk4_jar_override = gatk4_jar_override,
        preemptible_attempts = preemptible_attempts,
        m2_docker = m2_docker,
        m2_args = m2_args
    }
  }

  call MergeVCFs {
    input:
      gatk4_jar = gatk4_jar,
      input_vcfs = M2.output_vcf,
      output_vcf_name = ProcessOptionalArguments.output_name,
      gatk4_jar_override = gatk4_jar_override,
      preemptible_attempts = preemptible_attempts,
      m2_docker = m2_docker
  }

  if (is_run_orientation_bias_filter) {
      call CollectSequencingArtifactMetrics {
        input:
            preemptible_attempts = preemptible_attempts,
            m2_docker = m2_docker,
            tumor_bam = tumor_bam,
            tumor_bam_index = tumor_bam_index,
            ref_fasta = ref_fasta,
            ref_fasta_index = ref_fasta_index,
            picard_jar = picard_jar
      }
  }

  call Filter {
    input:
      gatk4_jar = gatk4_jar,
      gatk4_jar_override = gatk4_jar_override,
      unfiltered_vcf = MergeVCFs.output_vcf,
      output_vcf_name = ProcessOptionalArguments.output_name,
      intervals = intervals,
      m2_docker = m2_docker,
      preemptible_attempts = preemptible_attempts,
      pre_adapter_metrics = CollectSequencingArtifactMetrics.pre_adapter_metrics,
      tumor_bam = tumor_bam,
      tumor_bam_index = tumor_bam_index,
      ref_fasta = ref_fasta,
      ref_fasta_index = ref_fasta_index,
      artifact_modes = artifact_modes,
      variants_for_contamination = variants_for_contamination,
      variants_for_contamination_index = variants_for_contamination_index,
      m2_filtering_args = m2_filtering_args
  }


  if (is_run_oncotator) {
        call oncotate_m2 {
            input:
                m2_vcf = Filter.filtered_vcf,
                entity_id = tumor_sample_name,
                preemptible_attempts = preemptible_attempts,
                oncotator_docker = oncotator_docker,
                onco_ds_tar_gz = onco_ds_tar_gz,
                onco_ds_local_db_dir = onco_ds_local_db_dir
        }
  }

  output {
        File unfiltered_vcf = MergeVCFs.output_vcf
        File unfiltered_vcf_index = MergeVCFs.output_vcf_index
        File filtered_vcf = Filter.filtered_vcf
        File filtered_vcf_index = Filter.filtered_vcf_index

        # select_first() fails if nothing resulve to non-null, so putting in "/dev/null" for now.
        File? oncotated_m2_vcf = select_first([oncotate_m2.oncotated_m2_vcf, "null"])
  }
}

task M2 {
  String gatk4_jar
  File? intervals
  File ref_fasta
  File ref_fasta_index
  File ref_dict
  File tumor_bam
  File tumor_bam_index
  String tumor_sample_name
  File? normal_bam
  File? normal_bam_index
  String? normal_sample_name
  File? pon
  File? pon_index
  File? gnomad
  File? gnomad_index
  String output_vcf_name
  String m2_docker
  File? gatk4_jar_override
  Int preemptible_attempts
  String? m2_args

  command {
  if [[ "_${normal_bam}" == *.bam ]]; then
      normal_command_line="-I ${normal_bam} -normal ${normal_sample_name}"
  fi

  # Use GATK Jar override if specified
  GATK_JAR=${gatk4_jar}
  if [[ "${gatk4_jar_override}" == *.jar ]]; then
      GATK_JAR=${gatk4_jar_override}
  fi

    java -Xmx4g -jar $GATK_JAR Mutect2 \
    -R ${ref_fasta} \
    -I ${tumor_bam} \
    -tumor ${tumor_sample_name} \
    $normal_command_line \
    ${"--germline_resource " + gnomad} \
    ${"--normal_panel " + pon} \
    ${"-L " + intervals} \
    -O "${output_vcf_name}.vcf" \
    ${m2_args}
  }

  runtime {
      docker: "${m2_docker}"
      memory: "5 GB"
      disks: "local-disk " + 500 + " HDD"
      preemptible: "${preemptible_attempts}"
  }

  output {
    File output_vcf = "${output_vcf_name}.vcf"
  }
}

# HACK: cromwell can't handle the optional normal sample name in output or input --
# string interpolation of optionals only works inside a command block
# thus we use this hack
task ProcessOptionalArguments {
  String tumor_sample_name
  String? normal_bam
  String? normal_sample_name
  Int preemptible_attempts
  String m2_docker

  command {
      if [[ "_${normal_bam}" == *.bam ]]; then
        echo "${tumor_sample_name}-vs-${normal_sample_name}" > name.tmp
      else
        echo "${tumor_sample_name}-tumor-only" > name.tmp
      fi
  }

  runtime {
    docker: "broadinstitute/genomes-in-the-cloud:2.2.4-1469632282"
    memory: "2 GB"
    disks: "local-disk " + 10 + " HDD"
    preemptible: "${preemptible_attempts}"
  }

  output {
      String output_name = read_string("name.tmp")
  }
}

task MergeVCFs {
  String gatk4_jar
  Array[File] input_vcfs
  String output_vcf_name
  File? gatk4_jar_override
  Int preemptible_attempts
  String m2_docker

  # using MergeVcfs instead of GatherVcfs so we can create indices
  # WARNING 2015-10-28 15:01:48 GatherVcfs  Index creation not currently supported when gathering block compressed VCFs.
  command {
    # Use GATK Jar override if specified
    GATK_JAR=${gatk4_jar}
    if [[ "${gatk4_jar_override}" == *.jar ]]; then
        GATK_JAR=${gatk4_jar_override}
    fi

    java -Xmx2g -jar $GATK_JAR MergeVcfs -I ${sep=' -I ' input_vcfs} -O ${output_vcf_name}.vcf
  }

  runtime {
    docker: "${m2_docker}"
    memory: "3 GB"
    disks: "local-disk " + 300 + " HDD"
    preemptible: "${preemptible_attempts}"
  }

  output {
    File output_vcf = "${output_vcf_name}.vcf"
    File output_vcf_index = "${output_vcf_name}.vcf.idx"
  }
}

task CollectSequencingArtifactMetrics {
  Int preemptible_attempts
  String m2_docker
  File tumor_bam
  File tumor_bam_index
  File ref_fasta
  File ref_fasta_index
  File picard_jar

  command {
        java -Xmx4G -jar ${picard_jar} CollectSequencingArtifactMetrics I=${tumor_bam} O="metrics" R=${ref_fasta}

        # Convert to GATK format
        sed -r "s/picard\.analysis\.artifacts\.SequencingArtifactMetrics\\\$PreAdapterDetailMetrics/org\.broadinstitute\.hellbender\.tools\.picard\.analysis\.artifacts\.SequencingArtifactMetrics\$PreAdapterDetailMetrics/g" \
            "metrics.pre_adapter_detail_metrics" > "gatk.pre_adapter_detail_metrics"
  }

  runtime {
    docker: "${m2_docker}"
    memory: "5 GB"
    disks: "local-disk " + 500 + " HDD"
    preemptible: "${preemptible_attempts}"
  }

  output {
    File pre_adapter_metrics = "gatk.pre_adapter_detail_metrics"
  }
}

task Filter {
  String gatk4_jar
  File? gatk4_jar_override
  File unfiltered_vcf
  String output_vcf_name
  File? intervals
  Int preemptible_attempts
  String m2_docker
  File? pre_adapter_metrics
  File? tumor_bam
  File? tumor_bam_index
  File? ref_fasta
  File? ref_fasta_index
  Array[String]? artifact_modes
  File? variants_for_contamination
  File? variants_for_contamination_index
  String? m2_filtering_args

  command {
    set -e

    # Use GATK Jar override if specified
    GATK_JAR=${gatk4_jar}
    if [[ "${gatk4_jar_override}" == *.jar ]]; then
        GATK_JAR=${gatk4_jar_override}
    fi

    if [[ "${variants_for_contamination}" == *.vcf ]]; then
        java -Xmx4g -jar $GATK_JAR GetPileupSummaries -I ${tumor_bam} ${"-L " + intervals} -V ${variants_for_contamination} -O pileups.table
        java -Xmx4g -jar $GATK_JAR CalculateContamination -I pileups.table -O contamination.table
        contamination_cmd="-contaminationTable contamination.table"
    fi

    penultimate_variants=${unfiltered_vcf}
    if [[ ! -z "${pre_adapter_metrics}" ]]; then
        java -jar $GATK_JAR FilterByOrientationBias -A ${sep=" -A " artifact_modes} \
            -V ${unfiltered_vcf} -P ${pre_adapter_metrics} --output ob_filtered.vcf
        penultimate_variants=ob_filtered.vcf
    fi

  	java -Xmx4g -jar $GATK_JAR FilterMutectCalls -V $penultimate_variants \
  	    -O "${output_vcf_name}-filtered.vcf" $contamination_cmd \
  	    ${m2_filtering_args}
  }

  runtime {
    docker: "${m2_docker}"
    memory: "5 GB"
    disks: "local-disk " + 500 + " HDD"
    preemptible: "${preemptible_attempts}"
  }

  output {
    File filtered_vcf = "${output_vcf_name}-filtered.vcf"
    File filtered_vcf_index = "${output_vcf_name}-filtered.vcf.idx"
  }
}

task SplitIntervals {
  String gatk4_jar
  Int scatter_count
  File? intervals
  File ref_fasta
  File ref_fasta_index
  File ref_dict
  File? gatk4_jar_override
  Int preemptible_attempts
  String m2_docker

  command {
    # fail if *any* command below (not just the last) doesn't return 0, in particular if GATK SplitIntervals fails
    set -e

    # Use GATK Jar override if specified
    GATK_JAR=${gatk4_jar}
    if [[ "${gatk4_jar_override}" == *.jar ]]; then
        GATK_JAR=${gatk4_jar_override}
    fi

    mkdir interval-files
    java -jar $GATK_JAR SplitIntervals -R ${ref_fasta} ${"-L " + intervals} -scatter ${scatter_count} -O interval-files
    cp interval-files/*.intervals .
  }

  runtime {
    docker: "${m2_docker}"
    memory: "3 GB"
    disks: "local-disk " + 100 + " HDD"
    preemptible: "${preemptible_attempts}"
  }

  output {
    Array[File] interval_files = glob("*.intervals")
  }
}



task oncotate_m2 {
    File m2_vcf
    String entity_id
    Int preemptible_attempts
    String oncotator_docker
    File? onco_ds_tar_gz
    String? onco_ds_local_db_dir
    command {

          # fail if *any* command below (not just the last) doesn't return 0, in particular if wget fails
          set -e

          # local db dir is a directory and has been specified
          if [[ -d "${onco_ds_local_db_dir}" ]]; then
              echo "Using local db-dir: ${onco_ds_local_db_dir}"
              echo "THIS ONLY WORKS WITHOUT DOCKER!"
              ln -s ${onco_ds_local_db_dir} onco_dbdir

          elif [[ "${onco_ds_tar_gz}" == *.tar.gz ]]; then
              echo "Using given tar file: ${onco_ds_tar_gz}"
              tar zxvf ${onco_ds_tar_gz}
              ln -s oncotator_v1_ds_April052016 onco_dbdir

          else
              echo "Downloading and installing oncotator datasources from Broad FTP site..."
              # Download and untar the db-dir
              wget ftp://gsapubftp-anonymous@ftp.broadinstitute.org/bundle/oncotator/oncotator_v1_ds_April052016.tar.gz
              tar zxvf oncotator_v1_ds_April052016.tar.gz
              ln -s oncotator_v1_ds_April052016 onco_dbdir
          fi


        /root/oncotator_venv/bin/oncotator --db-dir onco_dbdir/ -c $HOME/tx_exact_uniprot_matches.AKT1_CRLF2_FGFR1.txt  \
            -v ${m2_vcf} ${entity_id}.oncotated.vcf hg19 -i VCF -o VCF --infer-onps --collapse-number-annotations --log_name oncotator.log
    }

    runtime {
        docker: "${oncotator_docker}"
        memory: "5 GB"
        bootDiskSizeGb: 10
        disks: "local-disk 150 SSD"
        preemptible: "${preemptible_attempts}"
    }

    output {
        File oncotated_m2_vcf="${entity_id}.oncotated.vcf"
    }
}
