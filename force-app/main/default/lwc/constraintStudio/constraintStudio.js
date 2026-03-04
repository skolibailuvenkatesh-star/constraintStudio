import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCMLSnippets from '@salesforce/apex/ConstraintStudioController.getCMLSnippets';
import deleteCMLSnippet from '@salesforce/apex/ConstraintStudioController.deleteCMLSnippet';
import saveCMLSnippet from '@salesforce/apex/ConstraintStudioController.saveCMLSnippet';
import createCMLSnippet from '@salesforce/apex/ConstraintStudioController.createCMLSnippet';
import getAttributeDefinitions from '@salesforce/apex/ConstraintStudioController.getAttributeDefinitions';
import getProductComponentSuggestions from '@salesforce/apex/ConstraintStudioController.getProductComponentSuggestions';
import getContextualProducts from '@salesforce/apex/ConstraintStudioController.getContextualProducts';
import getPicklistValues from '@salesforce/apex/ConstraintStudioController.getPicklistValues';
import findProductRelatedComponent from '@salesforce/apex/ConstraintStudioController.findProductRelatedComponent';
import getGlobalSnippet from '@salesforce/apex/ConstraintStudioController.getGlobalSnippet';
import getProductContext from '@salesforce/apex/ConstraintStudioController.getProductContext';
// F-01 imports
import saveVariableSnippet from '@salesforce/apex/ConstraintStudioController.saveVariableSnippet';
import saveAnnotationSnippet from '@salesforce/apex/ConstraintStudioController.saveAnnotationSnippet';


export default class ConstraintStudio extends LightningElement {
    @api recordId;
    @api objectApiName;

    // ==================== TAB STATE ====================
    @track activeTab = 'snippets';

    // ==================== SNIPPETS TAB STATE ====================
    @track searchTerm = '';
    @track snippets = [];
    @track groupedSnippets = {
        constraints: { label: 'Constraints', items: [], expanded: true, keyword: 'constraint' },
        require: { label: 'Require', items: [], expanded: true, keyword: 'require' },
        message: { label: 'Message', items: [], expanded: true, keyword: 'message' },
        setdefault: { label: 'SetDefault', items: [], expanded: true, keyword: 'setdefault' },
        rule: { label: 'Rule', items: [], expanded: true, keyword: 'rule' }
    };

    @track selectedSnippet = null;
    @track editLabel = '';
    @track editCML = '';
    @track isActive = true;
    @track showCMLEditor = false;
    @track isSaving = false;

    @track attributeDefinitions = [];
    @track productComponentSuggestions = [];
    @track idMappings = {};
    @track annotations = [];
    @track globalProperties = '';
    @track isPCGMode = true;
    @track productContext = null;
    @track contextExpanded = false;

    wiredSnippetsResult;
    allSuggestions = [];
    annotationCounter = 0;
    globalSnippetId = null;

    // ==================== F-01: ATTRIBUTES TAB STATE ====================
    @track attrSearchTerm = '';
    @track selectedAttrItem = null;
    @track attrAnnotations = [];
    @track editAttrName = '';
    @track editAttrType = 'string';
    @track editAttrDomain = '';
    @track editAttrDefaultValue = '';
    @track isSavingAttr = false;
    attrAnnotationCounter = 0;
    attrSectionExpandedMap = {};

    // ==================== TAB GETTERS ====================

    get isSnippetsTab() { return this.activeTab === 'snippets'; }
    get isAttributesTab() { return this.activeTab === 'attributes'; }
    get snippetsTabClass() { return 'tab-button' + (this.isSnippetsTab ? ' active' : ''); }
    get attributesTabClass() { return 'tab-button' + (this.isAttributesTab ? ' active' : ''); }

    handleTabChange(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    // ==================== DATA TYPE OPTIONS ====================

    get dataTypeOptions() {
        return [
            { label: 'string', value: 'string' },
            { label: 'decimal(2)', value: 'decimal(2)' },
            { label: 'boolean', value: 'boolean' },
            { label: 'date', value: 'date' },
            { label: 'integer', value: 'integer' }
        ];
    }

    // ==================== WIRE HANDLERS ====================

    @wire(getAttributeDefinitions, {
        recordId: '$recordId',
        objectApiName: '$objectApiName'
    })
    wiredAttributeDefinitions(result) {
        if (result.data) {
            this.updateCombinedSuggestions('attributes', result.data);
        } else if (result.error) {
            console.error('Error loading attribute definitions:', result.error);
        }
    }

    @wire(getProductComponentSuggestions, {
        recordId: '$recordId'
    })
    wiredProductComponentSuggestions(result) {
        if (this.objectApiName === 'Product2') {
            if (result.data) {
                this.updateCombinedSuggestions('products', result.data);
            } else if (result.error) {
                console.error('Error loading product component suggestions:', result.error);
            }
        }
    }

    updateCombinedSuggestions(source, data) {
        if (source === 'attributes') {
            this.attributeDefinitions = [...data];
        } else if (source === 'products') {
            this.productComponentSuggestions = [...data];
        }

        const combined = [
            ...this.attributeDefinitions,
            ...this.productComponentSuggestions
        ];

        this.allSuggestions = combined;
        this.attributeDefinitions = combined;
    }

    // ==================== TRANSLATION HELPERS ====================

    async translateToIds(cmlText) {
        if (!cmlText) return cmlText;

        let translated = cmlText;

        const bracketPattern = /([\w]+)\[([\w]+)\]/g;
        const matches = [...cmlText.matchAll(bracketPattern)];

        for (const match of matches) {
            const groupName = match[1];
            const productName = match[2];
            const fullPattern = match[0];

            const groupSuggestion = this.allSuggestions.find(s =>
                s.actualName === groupName && s.type === 'ProductComponentGroup'
            );
            const productSuggestion = this.allSuggestions.find(s =>
                s.actualName === productName && s.value && s.value.startsWith('Product2_')
            );

            if (groupSuggestion && productSuggestion) {
                const groupId = groupSuggestion.recordId;
                const productId = productSuggestion.value.replace('Product2_', '');

                try {
                    const result = await findProductRelatedComponent({
                        productComponentGroupId: groupId,
                        product2Id: productId
                    });

                    if (result) {
                        let replacement;
                        if (result.useProductComponentGroup === 'true') {
                            replacement = `REL_ProductComponentGroup_${result.groupId}[Product2_${productId}]`;
                        } else {
                            replacement = `REL_ProductRelatedComponent_${result.prcId}[Product2_${productId}]`;
                        }
                        translated = translated.replace(fullPattern, replacement);
                    }
                } catch (error) {
                    console.error('Error finding ProductRelatedComponent:', error);
                }
            }
        }

        this.allSuggestions.forEach(suggestion => {
            if (suggestion.actualName && suggestion.value) {
                if (suggestion.type === 'Attribute') {
                    const regex = new RegExp('\\b' + this.escapeRegex(suggestion.actualName) + '\\b', 'g');
                    translated = translated.replace(regex, suggestion.value);
                }
            }
        });

        return translated;
    }

    translateToDisplayNames(cmlText) {
        if (!cmlText) return cmlText;

        let translated = cmlText;

        this.allSuggestions.forEach(suggestion => {
            if (suggestion.value && suggestion.actualName) {
                if (suggestion.type === 'ProductComponentGroup' ||
                    suggestion.type === 'Product' ||
                    suggestion.value.startsWith('Product2_')) {
                    const regex = new RegExp('\\b' + this.escapeRegex(suggestion.value) + '\\b', 'g');
                    translated = translated.replace(regex, suggestion.actualName);
                }
            }
        });

        return translated;
    }

    escapeRegex(str) {
        return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    // ==================== LIFECYCLE ====================

    connectedCallback() {
        this.loadSnippets();
        this.loadGlobalSnippet();
        this.loadProductContext();
    }

    async loadGlobalSnippet() {
        try {
            const snippet = await getGlobalSnippet({
                recordId: this.recordId,
                objectApiName: this.objectApiName
            });
            if (snippet) {
                this.globalSnippetId = snippet.Id;
                const raw = snippet.CML__c || '';
                const lines = raw.split('\n');
                const filtered = [];
                for (const line of lines) {
                    const trimmed = line.trim();
                    if (trimmed.startsWith('// mode:')) continue;
                    filtered.push(line);
                }
                this.globalProperties = filtered.join('\n');
            }
        } catch (error) {
            console.error('Error loading global snippet:', error);
        }
    }

    async loadProductContext() {
        try {
            this.productContext = await getProductContext({
                recordId: this.recordId,
                objectApiName: this.objectApiName
            });
        } catch (error) {
            console.error('Error loading product context:', error);
        }
    }

    // ==================== PRODUCT CONTEXT GETTERS ====================

    get hasProductContext() {
        return this.productContext != null;
    }

    get hasProductAttributes() {
        return this.productContext?.productAttributes?.length > 0;
    }

    get hasClassificationAttributes() {
        return this.productContext?.classificationAttributes?.length > 0;
    }

    get hasBundleTree() {
        return this.productContext?.bundleTree?.length > 0;
    }

    get formattedBundleTree() {
        if (!this.productContext?.bundleTree) return [];
        return this.productContext.bundleTree.map(node => ({
            ...node,
            isGroup: node.nodeType === 'group',
            isBundle: node.nodeType === 'bundle',
            isProduct: node.nodeType === 'product',
            indentStyle: `padding-left: ${(node.depth * 16) + 16}px`,
            hasAttributes: node.attributes && node.attributes.length > 0,
            formattedAttributes: (node.attributes || []).map(a => ({
                ...a,
                hasDomain: a.domain && a.domain.length > 0,
                domainStr: a.domain ? a.domain.join(', ') : ''
            })),
            hasVariables: node.variables && node.variables.length > 0,
            formattedVariables: (node.variables || []).map(v => ({
                ...v,
                dataType: this.parseVariableCml(v.cml).dataType
            }))
        }));
    }

    get formattedProductAttributes() {
        if (!this.productContext?.productAttributes) return [];
        return this.productContext.productAttributes.map(a => ({
            ...a,
            hasDomain: a.domain && a.domain.length > 0,
            domainStr: a.domain ? a.domain.join(', ') : ''
        }));
    }

    get formattedClassificationAttributes() {
        if (!this.productContext?.classificationAttributes) return [];
        return this.productContext.classificationAttributes.map(a => ({
            ...a,
            hasDomain: a.domain && a.domain.length > 0,
            domainStr: a.domain ? a.domain.join(', ') : ''
        }));
    }

    // F-01: Variables in Available Context
    get hasContextVariables() {
        return this.productContext?.variables?.length > 0;
    }

    get formattedContextVariables() {
        if (!this.productContext?.variables) return [];
        return this.productContext.variables.map(v => ({
            ...v,
            dataType: this.parseVariableCml(v.cml).dataType
        }));
    }

    get contextToggleIcon() {
        return this.contextExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }

    handleContextToggle() {
        this.contextExpanded = !this.contextExpanded;
    }

    // ==================== SNIPPETS TAB: LOAD & GROUP ====================

    async loadSnippets() {
        try {
            const data = await getCMLSnippets({
                recordId: this.recordId,
                objectApiName: this.objectApiName,
                searchTerm: this.searchTerm,
                cacheBuster: String(Date.now())
            });
            this.snippets = data;
            this.groupSnippets();
        } catch (error) {
            this.showToast('Error', 'Error loading CML Snippets: ' + error.body.message, 'error');
        }
    }

    groupSnippets() {
        Object.keys(this.groupedSnippets).forEach(key => {
            this.groupedSnippets[key].items = [];
        });

        this.snippets.forEach(snippet => {
            const cml = snippet.CML__c ? snippet.CML__c.toLowerCase() : '';
            let grouped = false;

            const enhancedSnippet = {
                ...snippet,
                isSelected: this.selectedSnippet && snippet.Id === this.selectedSnippet.Id ? 'snippet-item selected' : 'snippet-item'
            };

            if (cml.includes('constraint')) {
                this.groupedSnippets.constraints.items.push(enhancedSnippet);
                grouped = true;
            }
            if (cml.includes('require')) {
                this.groupedSnippets.require.items.push(enhancedSnippet);
                grouped = true;
            }
            if (cml.includes('message')) {
                this.groupedSnippets.message.items.push(enhancedSnippet);
                grouped = true;
            }
            if (cml.includes('setdefault')) {
                this.groupedSnippets.setdefault.items.push(enhancedSnippet);
                grouped = true;
            }
            if (cml.includes('rule')) {
                this.groupedSnippets.rule.items.push(enhancedSnippet);
                grouped = true;
            }
            if (!grouped) {
                this.groupedSnippets.constraints.items.push(enhancedSnippet);
            }
        });
    }

    get sections() {
        return Object.keys(this.groupedSnippets).map(key => ({
            key: key,
            label: this.groupedSnippets[key].label,
            items: this.groupedSnippets[key].items,
            expanded: this.groupedSnippets[key].expanded,
            hasItems: this.groupedSnippets[key].items.length > 0,
            keyword: this.groupedSnippets[key].keyword
        }));
    }

    get hasSelectedSnippet() {
        return this.selectedSnippet !== null;
    }

    get displayLabel() {
        return this.editLabel || this.selectedSnippet?.Name || 'New Snippet';
    }

    get highlightedCML() {
        if (!this.editCML) return '';
        let highlighted = this.editCML;
        const keywords = ['constraint', 'require', 'message', 'setdefault', 'rule'];
        keywords.forEach(keyword => {
            const regex = new RegExp(`\\b${keyword}\\b`, 'gi');
            highlighted = highlighted.replace(regex, `<span class="keyword">${keyword}</span>`);
        });
        return highlighted;
    }

    get hasAnnotations() {
        return this.annotations && this.annotations.length > 0;
    }

    // ==================== SNIPPETS TAB: HANDLERS ====================

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        this.loadSnippets();
    }

    handleToggleSection(event) {
        const sectionKey = event.currentTarget.dataset.key;
        this.groupedSnippets[sectionKey].expanded = !this.groupedSnippets[sectionKey].expanded;
        this.groupedSnippets = { ...this.groupedSnippets };
    }

    async handleAddSnippet(event) {
        const sectionKey = event.currentTarget.dataset.key;
        const keyword = this.groupedSnippets[sectionKey].keyword;

        try {
            const newSnippet = await createCMLSnippet({
                recordId: this.recordId,
                objectApiName: this.objectApiName,
                keyword: keyword,
                label: ''
            });

            this.showToast('Success', 'CML Snippet created successfully', 'success');
            await this.loadSnippets();

            const refreshedSnippet = this.snippets.find(s => s.Id === newSnippet.Id);
            this.selectSnippet(refreshedSnippet || newSnippet, true);
        } catch (error) {
            this.showToast('Error', 'Error creating CML Snippet: ' + error.body.message, 'error');
        }
    }

    async handleDeleteSnippet(event) {
        const snippetId = event.currentTarget.dataset.id;
        const snippetLabel = event.currentTarget.dataset.label;
        const snippetName = event.currentTarget.dataset.name;
        const displayName = snippetLabel || snippetName;

        if (confirm(`Are you sure you want to delete "${displayName}"?`)) {
            try {
                await deleteCMLSnippet({ snippetId: snippetId });
                this.showToast('Success', 'CML Snippet deleted successfully', 'success');

                if (this.selectedSnippet && this.selectedSnippet.Id === snippetId) {
                    this.selectedSnippet = null;
                }
                await this.loadSnippets();
            } catch (error) {
                this.showToast('Error', 'Error deleting CML Snippet: ' + error.body.message, 'error');
            }
        }
    }

    handleSnippetClick(event) {
        const snippetId = event.currentTarget.dataset.id;
        const snippet = this.snippets.find(s => s.Id === snippetId);
        if (snippet) {
            this.selectSnippet(snippet);
        }
    }

    selectSnippet(snippet, isNewSnippet = false) {
        this.selectedSnippet = snippet;
        this.editLabel = snippet.Label__c || '';

        const { isActive, cmlCode } = this.parseActiveAnnotation(snippet.CML__c || '');
        this.isActive = isActive;
        this.editCML = this.translateToDisplayNames(cmlCode);
        this.showCMLEditor = isNewSnippet;
        this.groupSnippets();
    }

    parseActiveAnnotation(cmlText) {
        if (!cmlText) {
            this.annotations = [];
            return { isActive: true, cmlCode: '' };
        }

        const annotationMatch = cmlText.match(/^@\(([^)]+)\)\s*/);

        if (annotationMatch) {
            const annotationContent = annotationMatch[1];
            const cmlCode = cmlText.substring(annotationMatch[0].length);

            let isActive = true;
            const parsedAnnotations = [];

            const parts = annotationContent.split(',').map(p => p.trim());

            parts.forEach(part => {
                const eqIdx = part.indexOf('=');
                if (eqIdx === -1) return;

                const key = part.substring(0, eqIdx).trim();
                let val = part.substring(eqIdx + 1).trim();
                val = val.replace(/^["']|["']$/g, '');

                if (key === 'active') {
                    isActive = val === 'true';
                } else {
                    parsedAnnotations.push({
                        id: `annotation-${this.annotationCounter++}`,
                        type: key,
                        value: val
                    });
                }
            });

            this.annotations = parsedAnnotations;
            return { isActive, cmlCode };
        }

        this.annotations = [];
        return { isActive: true, cmlCode: cmlText };
    }

    convertToISODate(dateStr) {
        if (!dateStr) return '';
        const parts = dateStr.split('/');
        if (parts.length === 3) {
            const [month, day, year] = parts;
            return `${year}-${month.padStart(2, '0')}-${day.padStart(2, '0')}`;
        }
        return dateStr;
    }

    convertToUSDate(isoDate) {
        if (!isoDate) return '';
        const parts = isoDate.split('-');
        if (parts.length === 3) {
            const [year, month, day] = parts;
            return `${month}/${day}/${year}`;
        }
        return isoDate;
    }

    handleActiveToggle(event) {
        this.isActive = event.target.checked;
    }

    handleGlobalPropertiesChange(event) {
        this.globalProperties = event.target.value;
    }

    handleModeToggle(event) {
        this.isPCGMode = event.target.checked;
    }

    buildGlobalCmlForSave() {
        const props = this.globalProperties ? this.globalProperties.trim() : '';
        return props ? '// mode:pcg\n' + props : '// mode:pcg';
    }

    async handleGlobalPropertiesSave() {
        try {
            const cmlToSave = this.buildGlobalCmlForSave();
            if (this.globalSnippetId) {
                await saveCMLSnippet({
                    snippetId: this.globalSnippetId,
                    label: '__GLOBAL__',
                    cml: cmlToSave
                });
            } else {
                const newSnippet = await createCMLSnippet({
                    recordId: this.recordId,
                    objectApiName: this.objectApiName,
                    keyword: 'global',
                    label: '__GLOBAL__'
                });
                this.globalSnippetId = newSnippet.Id;
                await saveCMLSnippet({
                    snippetId: this.globalSnippetId,
                    label: '__GLOBAL__',
                    cml: cmlToSave
                });
            }
            this.showToast('Success', 'Global properties saved', 'success');
        } catch (error) {
            this.showToast('Error', 'Error saving global properties: ' + error.body?.message, 'error');
        }
    }

    handleLabelChange(event) {
        this.editLabel = event.target.value;
    }

    handleCMLChange(event) {
        this.editCML = event.detail.value;
    }

    handleToggleCML(event) {
        this.showCMLEditor = event.target.checked;
    }

    async handlePicklistRequest(event) {
        const { attributeName } = event.detail;
        try {
            const picklistValues = await getPicklistValues({
                recordId: this.recordId,
                objectApiName: this.objectApiName,
                attributeName: attributeName
            });
            const codeEditor = this.template.querySelector('c-cml-code-editor');
            if (codeEditor) {
                codeEditor.showContextualSuggestions(picklistValues);
            }
        } catch (error) {
            console.error('Error fetching picklist values:', error);
        }
    }

    async handleContextRequest(event) {
        const { contextValue } = event.detail;

        let contextId, contextType;
        if (contextValue.startsWith('REL_ProductComponentGroup_')) {
            contextId = contextValue.replace('REL_ProductComponentGroup_', '');
            contextType = 'ProductComponentGroup';
        } else if (contextValue.startsWith('REL_ProductRelatedComponent_')) {
            contextId = contextValue.replace('REL_ProductRelatedComponent_', '');
            contextType = 'ProductRelatedComponent';
        } else {
            return;
        }

        try {
            const contextualProducts = await getContextualProducts({
                contextId: contextId,
                contextType: contextType
            });

            contextualProducts.forEach(product => {
                const exists = this.allSuggestions.find(s => s.value === product.value);
                if (!exists) {
                    this.allSuggestions.push(product);
                }
            });

            const codeEditor = this.template.querySelector('c-cml-code-editor');
            if (codeEditor) {
                codeEditor.showContextualSuggestions(contextualProducts);
            }
        } catch (error) {
            console.error('Error fetching contextual products:', error);
        }
    }

    async handleSave() {
        if (!this.selectedSnippet) return;

        this.isSaving = true;
        try {
            let cmlToSave = await this.translateToIds(this.editCML);

            const annotationParts = [`active=${this.isActive}`];

            this.annotations.forEach(ann => {
                if (ann.type && (ann.value !== undefined && ann.value !== '')) {
                    const val = ann.value;
                    if (val === 'true' || val === 'false' || val === true || val === false) {
                        annotationParts.push(`${ann.type}=${val}`);
                    } else if (!isNaN(val) && val !== '') {
                        annotationParts.push(`${ann.type}=${val}`);
                    } else {
                        annotationParts.push(`${ann.type}="${val}"`);
                    }
                }
            });

            const fullAnnotation = `@(${annotationParts.join(', ')})\n`;
            cmlToSave = fullAnnotation + cmlToSave;

            await saveCMLSnippet({
                snippetId: this.selectedSnippet.Id,
                label: this.editLabel,
                cml: cmlToSave
            });

            this.showToast('Success', 'CML Snippet saved successfully', 'success');
            await this.loadSnippets();

            const updatedSnippet = this.snippets.find(s => s.Id === this.selectedSnippet.Id);
            if (updatedSnippet) {
                this.selectSnippet(updatedSnippet);
            }
        } catch (error) {
            this.showToast('Error', 'Error saving CML Snippet: ' + error.body.message, 'error');
        } finally {
            this.isSaving = false;
        }
    }

    // Snippet annotation handlers
    handleAddAnnotation() {
        const newAnnotation = {
            id: `annotation-${this.annotationCounter++}`,
            type: '',
            value: ''
        };
        this.annotations = [...this.annotations, newAnnotation];
    }

    handleAnnotationTypeChange(event) {
        const annotationId = event.currentTarget.dataset.id;
        const newType = event.target.value;
        this.annotations = this.annotations.map(ann =>
            ann.id === annotationId ? { ...ann, type: newType } : ann
        );
    }

    handleAnnotationValueChange(event) {
        const annotationId = event.currentTarget.dataset.id;
        const newValue = event.target.value;
        this.annotations = this.annotations.map(ann =>
            ann.id === annotationId ? { ...ann, value: newValue } : ann
        );
    }

    handleDeleteAnnotation(event) {
        const annotationId = event.currentTarget.dataset.id;
        this.annotations = this.annotations.filter(ann => ann.id !== annotationId);
    }

    // ==================== F-01: ATTRIBUTES TAB LOGIC ====================

    handleAttrSearchChange(event) {
        this.attrSearchTerm = event.target.value;
    }

    handleToggleAttrSection(event) {
        const key = event.currentTarget.dataset.key;
        this.attrSectionExpandedMap = {
            ...this.attrSectionExpandedMap,
            [key]: !(this.attrSectionExpandedMap[key] !== false)
        };
    }

    // Parse variable CML to extract dataType, domain, and annotations
    parseVariableCml(cml) {
        if (!cml) return { dataType: 'string', domain: [], annotations: {} };

        // Strip @() annotation prefix
        let declaration = cml.replace(/^@\([^)]*\)\s*/s, '').trim().replace(/;$/, '').trim();

        const spaceIdx = declaration.indexOf(' ');
        if (spaceIdx <= 0) return { dataType: 'string', domain: [], annotations: {} };

        const dataType = declaration.substring(0, spaceIdx);
        const rest = declaration.substring(spaceIdx + 1).trim();

        // Check for default value or domain
        const domain = [];
        let defaultValue = '';
        const eqIdx = rest.indexOf('=');
        if (eqIdx > 0) {
            const valStr = rest.substring(eqIdx + 1).trim();
            const domainMatch = valStr.match(/\[(.*)\]/s);
            if (domainMatch) {
                // Domain values: = ["a", "b"]
                const values = domainMatch[1].split(',').map(v => v.trim().replace(/^"|"$/g, '')).filter(v => v);
                domain.push(...values);
            } else {
                // Single default value: = "Sharath"
                defaultValue = valStr.replace(/^"|"$/g, '');
            }
        }

        // Parse annotations
        const annotations = {};
        const annMatch = cml.match(/^@\(([^)]*)\)/);
        if (annMatch) {
            const parts = annMatch[1].split(',');
            for (const part of parts) {
                const kvMatch = part.trim().match(/^(\w+)\s*=\s*(.+)$/);
                if (kvMatch) {
                    const key = kvMatch[1];
                    if (key !== 'active') {
                        annotations[key] = kvMatch[2].trim().replace(/^"|"$/g, '');
                    }
                }
            }
        }

        return { dataType, domain, annotations, defaultValue };
    }

    // Build sections for Attributes tab left pane
    get attrSections() {
        const sections = [];
        const searchLower = (this.attrSearchTerm || '').toLowerCase();
        const annSnippets = this.productContext?.annotationSnippets || [];

        // This Product section
        const thisItems = [];
        const productAttrs = this.productContext?.productAttributes || [];
        for (const attr of productAttrs) {
            if (searchLower && !attr.name.toLowerCase().includes(searchLower)) continue;
            const annSnippet = annSnippets.find(s => s.name === attr.name);
            thisItems.push(this._buildAttrItem('sys-' + attr.name, attr.name, attr.dataType, attr.domain, 'sys', annSnippet));
        }

        const vars = this.productContext?.variables || [];
        for (const v of vars) {
            if (searchLower && !v.name.toLowerCase().includes(searchLower)) continue;
            const parsed = this.parseVariableCml(v.cml);
            const item = this._buildAttrItem('var-' + v.id, v.name, parsed.dataType, parsed.domain, 'var', null);
            item.snippetId = v.id;
            item.cml = v.cml;
            item.isVar = true;
            item.varAnnotations = parsed.annotations;
            thisItems.push(item);
        }

        sections.push({
            key: 'thisProduct',
            label: 'This Product',
            count: thisItems.length,
            items: thisItems,
            expanded: this.attrSectionExpandedMap.thisProduct !== false,
            hasItems: thisItems.length > 0,
            hasAdd: true
        });

        // Inherited section
        const classAttrs = this.productContext?.classificationAttributes || [];
        if (classAttrs.length > 0) {
            const inheritedItems = [];
            for (const attr of classAttrs) {
                if (searchLower && !attr.name.toLowerCase().includes(searchLower)) continue;
                inheritedItems.push(this._buildAttrItem('cls-' + attr.name, attr.name, attr.dataType, attr.domain, 'cls', null));
            }
            sections.push({
                key: 'inherited',
                label: 'Inherited: ' + (this.productContext?.classificationName || ''),
                count: inheritedItems.length,
                items: inheritedItems,
                expanded: this.attrSectionExpandedMap.inherited !== false,
                hasItems: inheritedItems.length > 0,
                hasAdd: false
            });
        }

        // Bundle child sections
        const tree = this.productContext?.bundleTree || [];
        for (const node of tree) {
            if (node.nodeType === 'group') continue;
            const nodeItems = [];
            for (const attr of (node.attributes || [])) {
                if (searchLower && !attr.name.toLowerCase().includes(searchLower)) continue;
                const item = this._buildAttrItem(`child-${node.id}-${attr.name}`, attr.name, attr.dataType, attr.domain, 'sys', null);
                item.readOnly = true;
                nodeItems.push(item);
            }
            for (const v of (node.variables || [])) {
                if (searchLower && !v.name.toLowerCase().includes(searchLower)) continue;
                const parsed = this.parseVariableCml(v.cml);
                const item = this._buildAttrItem(`childvar-${v.id}`, v.name, parsed.dataType, parsed.domain, 'var', null);
                item.readOnly = true;
                item.isVar = false; // read-only in parent — no delete
                nodeItems.push(item);
            }
            if (nodeItems.length > 0) {
                const sectionKey = 'child-' + node.id;
                sections.push({
                    key: sectionKey,
                    label: node.name,
                    count: nodeItems.length,
                    items: nodeItems,
                    expanded: this.attrSectionExpandedMap[sectionKey] !== false,
                    hasItems: true,
                    hasAdd: false
                });
            }
        }

        return sections;
    }

    _buildAttrItem(id, name, dataType, domain, source, annSnippet) {
        const isSelected = this.selectedAttrItem && this.selectedAttrItem.id === id;
        return {
            id,
            name,
            dataType: dataType || 'string',
            domain: domain || [],
            source,
            badge: source,
            icon: source === 'var' ? 'utility:edit' : source === 'cls' ? 'utility:bookmark' : 'utility:settings',
            badgeClass: `attr-badge ${source}`,
            itemClass: isSelected ? 'snippet-item selected' : 'snippet-item',
            isVar: source === 'var',
            readOnly: false,
            snippetId: annSnippet ? annSnippet.id : null,
            annotationCml: annSnippet ? annSnippet.cml : '',
            varAnnotations: {}
        };
    }

    get hasSelectedAttrItem() {
        return this.selectedAttrItem !== null;
    }

    get selectedAttrIsVar() {
        return this.selectedAttrItem?.source === 'var';
    }

    get selectedAttrHasDomain() {
        return this.selectedAttrItem?.domain?.length > 0 && this.selectedAttrItem?.source !== 'var';
    }

    get selectedAttrDomainStr() {
        return this.selectedAttrItem?.domain?.join(', ') || '';
    }

    get hasAttrAnnotations() {
        return this.attrAnnotations && this.attrAnnotations.length > 0;
    }

    handleAttrItemClick(event) {
        const itemId = event.currentTarget.dataset.id;
        // Find the item across all sections
        for (const section of this.attrSections) {
            const item = section.items.find(i => i.id === itemId);
            if (item) {
                this.selectAttrItem(item);
                break;
            }
        }
    }

    selectAttrItem(item) {
        this.selectedAttrItem = { ...item };

        if (item.source === 'var') {
            // For variables: populate editable fields
            const parsed = this.parseVariableCml(item.cml);
            this.editAttrName = item.name;
            this.editAttrType = parsed.dataType || 'string';
            this.editAttrDomain = parsed.domain ? parsed.domain.map(v => `"${v}"`).join(', ') : '';
            this.editAttrDefaultValue = parsed.defaultValue || '';

            // Parse annotations from variable CML
            const anns = parsed.annotations || {};
            this.attrAnnotations = Object.entries(anns).map(([key, value]) => ({
                id: `aann-${this.attrAnnotationCounter++}`,
                type: key,
                value: String(value)
            }));
        } else {
            // For sys/cls: populate from annotation snippet
            this.editAttrName = item.name;
            this.editAttrType = item.dataType;
            this.editAttrDomain = '';

            // Parse annotations from annotation snippet CML
            this.attrAnnotations = [];
            if (item.annotationCml) {
                const annMatch = item.annotationCml.match(/@\(([^)]*)\)/);
                if (annMatch) {
                    const parts = annMatch[1].split(',');
                    for (const part of parts) {
                        const kvMatch = part.trim().match(/^(\w+)\s*=\s*(.+)$/);
                        if (kvMatch) {
                            this.attrAnnotations.push({
                                id: `aann-${this.attrAnnotationCounter++}`,
                                type: kvMatch[1],
                                value: kvMatch[2].trim().replace(/^"|"$/g, '')
                            });
                        }
                    }
                }
            }
        }
    }

    handleAttrNameChange(event) {
        this.editAttrName = event.target.value;
    }

    handleAttrTypeChange(event) {
        this.editAttrType = event.detail.value;
    }

    handleAttrDomainChange(event) {
        this.editAttrDomain = event.target.value;
    }

    handleAttrDefaultValueChange(event) {
        this.editAttrDefaultValue = event.target.value;
    }

    // Attribute annotation handlers
    handleAddAttrAnnotation() {
        this.attrAnnotations = [...this.attrAnnotations, {
            id: `aann-${this.attrAnnotationCounter++}`,
            type: '',
            value: ''
        }];
    }

    handleAttrAnnotationTypeChange(event) {
        const id = event.currentTarget.dataset.id;
        const newType = event.target.value;
        this.attrAnnotations = this.attrAnnotations.map(a =>
            a.id === id ? { ...a, type: newType } : a
        );
    }

    handleAttrAnnotationValueChange(event) {
        const id = event.currentTarget.dataset.id;
        const newValue = event.target.value;
        this.attrAnnotations = this.attrAnnotations.map(a =>
            a.id === id ? { ...a, value: newValue } : a
        );
    }

    handleDeleteAttrAnnotation(event) {
        const id = event.currentTarget.dataset.id;
        this.attrAnnotations = this.attrAnnotations.filter(a => a.id !== id);
    }

    // Build annotation CML string from attrAnnotations
    _buildAnnotationCml() {
        const parts = [];
        for (const ann of this.attrAnnotations) {
            if (!ann.type) continue;
            const val = ann.value;
            if (val === 'true' || val === 'false') {
                parts.push(`${ann.type}=${val}`);
            } else if (!isNaN(val) && val !== '') {
                parts.push(`${ann.type}=${val}`);
            } else {
                parts.push(`${ann.type}="${val}"`);
            }
        }
        return parts.length > 0 ? `@(${parts.join(', ')})` : '';
    }

    // Save attribute/variable
    async handleSaveAttr() {
        if (!this.selectedAttrItem) return;
        this.isSavingAttr = true;

        try {
            if (this.selectedAttrItem.source === 'var') {
                // Save variable
                const annotationCml = this._buildAnnotationCml();
                await saveVariableSnippet({
                    recordId: this.recordId,
                    objectApiName: this.objectApiName,
                    snippetId: this.selectedAttrItem.snippetId || null,
                    varName: this.editAttrName,
                    varType: this.editAttrType,
                    domainValues: this.editAttrDomain,
                    defaultValue: this.editAttrDefaultValue,
                    annotationCml: annotationCml
                });
                this.showToast('Success', 'Variable saved', 'success');
            } else {
                // Save attribute annotation
                const annotationCml = this._buildAnnotationCml();
                await saveAnnotationSnippet({
                    recordId: this.recordId,
                    objectApiName: this.objectApiName,
                    snippetId: this.selectedAttrItem.snippetId || null,
                    attributeName: this.selectedAttrItem.name,
                    annotationCml: annotationCml
                });
                this.showToast('Success', 'Annotation saved', 'success');
            }

            // Reload product context to refresh variables and annotations
            await this.loadProductContext();
            // Re-select the item to refresh editor state
            const itemId = this.selectedAttrItem.id;
            this.selectedAttrItem = null;
            // Wait for reactivity, then find and re-select
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                for (const section of this.attrSections) {
                    const item = section.items.find(i => i.id === itemId || i.name === this.editAttrName);
                    if (item) {
                        this.selectAttrItem(item);
                        break;
                    }
                }
            }, 100);
        } catch (error) {
            this.showToast('Error', 'Error saving: ' + (error.body?.message || error.message), 'error');
        } finally {
            this.isSavingAttr = false;
        }
    }

    // Add variable
    async handleAddVariable() {
        try {
            await saveVariableSnippet({
                recordId: this.recordId,
                objectApiName: this.objectApiName,
                snippetId: null,
                varName: 'NewVariable',
                varType: 'string',
                domainValues: '',
                defaultValue: '',
                annotationCml: ''
            });
            this.showToast('Success', 'Variable created', 'success');
            await this.loadProductContext();
        } catch (error) {
            this.showToast('Error', 'Error creating variable: ' + (error.body?.message || error.message), 'error');
        }
    }

    // Delete variable
    async handleDeleteVariable(event) {
        const snippetId = event.currentTarget.dataset.id;
        if (!confirm('Delete this variable?')) return;

        try {
            await deleteCMLSnippet({ snippetId: snippetId });
            this.showToast('Success', 'Variable deleted', 'success');

            if (this.selectedAttrItem && this.selectedAttrItem.snippetId === snippetId) {
                this.selectedAttrItem = null;
            }
            await this.loadProductContext();
        } catch (error) {
            this.showToast('Error', 'Error deleting variable: ' + (error.body?.message || error.message), 'error');
        }
    }

    // ==================== UTILITIES ====================

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        }));
    }
}
